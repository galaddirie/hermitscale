defmodule Hermitscale.Credentials do
  @moduledoc """
  Credential lifecycle and resolution, backend-agnostic.

  Metadata (scope, provider, kind, status) lives in the `credentials` table;
  secret material lives with the backend recorded on each credential row (see
  `Hermitscale.Credentials.Backend`). Everything that must behave identically
  across backends is owned here: tenancy checks, the status lifecycle, OAuth
  refresh with per-credential single-flight, token caching, and audit.

  Refresh single-flight uses a Postgres advisory lock keyed on the credential
  id, so it holds across BEAM nodes. New token payloads are persisted before
  first use — required for providers with rotating refresh tokens.

  Audit: every create/connect/access/refresh/rotate/revoke appends a
  `credential_events` row and emits `[:hermitscale, :credentials, <action>]`
  telemetry. Cache hits emit telemetry only (an event row per cache hit would
  drown the table without adding information — the initiating access is
  already recorded).
  """

  import Ecto.Query

  alias Hermitscale.Credentials.{
    AccessToken,
    Backend,
    Credential,
    CredentialEvent,
    Resolved,
    SecretPayload,
    TokenCache
  }

  alias Hermitscale.Credentials.SecretPayload.OAuthToken
  alias Hermitscale.Integrations.Provider
  alias Hermitscale.Repo

  @refresh_margin_seconds 60
  @managed_cache_ttl_seconds 60
  @no_expiry_cache_ttl_seconds 300
  @advisory_lock_namespace 174_002

  @builtin_backends [
    Hermitscale.Credentials.Backends.Local,
    Hermitscale.Credentials.Backends.WorkOS
  ]

  # --- Lifecycle ---

  @doc """
  Stores a new credential from a `SecretPayload` (API key, custom fields, or
  an imported OAuth token pair). Interactive OAuth connections go through
  `connect/3` instead.
  """
  def create(scope, attrs) when is_map(scope) and is_map(attrs) do
    payload = Map.fetch!(attrs, :payload)
    kind = SecretPayload.kind(payload)
    method = attrs[:method] || Atom.to_string(kind)
    provider = Map.fetch!(attrs, :provider)
    backend = attrs[:backend] || default_backend()

    with :ok <- validate_method(provider, method) do
      credential_attrs = %{
        id: Ecto.UUID.generate(),
        org_id: Map.fetch!(scope, :org_id),
        user_id: scope[:user_id],
        provider: provider,
        kind: kind,
        method: method,
        name: attrs[:name] || provider,
        status: :active,
        backend: backend.id(),
        provider_metadata: attrs[:provider_metadata] || %{},
        scopes: attrs[:scopes] || payload_scopes(payload),
        expires_at: payload_expiry(payload)
      }

      insert_with_secret(credential_attrs, payload, backend, attrs[:actor] || "system")
    end
  end

  @doc """
  Begins an OAuth connect flow: creates a `:pending_connect` credential and
  returns what the frontend needs — backend widget config for managed-OAuth
  backends, or an authorization URL for self-managed ones. The flow completes
  through `complete_connect/3`.
  """
  def connect(scope, provider, opts \\ []) when is_map(scope) and is_binary(provider) do
    backend = opts[:backend] || default_backend()

    with {:ok, oauth_spec} <- oauth_method_spec(provider) do
      scopes = opts[:scopes] || oauth_spec[:default_scopes] || []

      changeset =
        Credential.changeset(%Credential{}, %{
          id: Ecto.UUID.generate(),
          org_id: Map.fetch!(scope, :org_id),
          user_id: scope[:user_id],
          provider: provider,
          kind: :oauth,
          method: "oauth",
          name: opts[:name] || provider,
          status: :pending_connect,
          backend: backend.id(),
          scopes: scopes
        })

      Repo.transaction(fn ->
        with {:ok, credential} <- Repo.insert(changeset),
             {:ok, connect_config} <- connect_config(backend, credential, oauth_spec) do
          record_event(credential, :created, opts[:actor] || "system", %{flow: "connect"})
          %{credential: credential, connect: connect_config}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  Completes a connect flow started by `connect/3`.

  Self-managed backends pass `%{code: code}` from the OAuth callback and the
  authorization code is exchanged here. Managed-OAuth backends pass
  `%{external_ref: ref}` (e.g. the WorkOS Pipes connection id) once their
  flow reports the connection.
  """
  def complete_connect(credential_id, params, opts \\ []) do
    with {:ok, credential} <- fetch(credential_id),
         :ok <- ensure_status(credential, [:pending_connect, :reauth_required]) do
      backend = backend_for(credential)

      if Backend.capability?(backend, :managed_oauth) do
        complete_managed_connect(credential, params, opts)
      else
        complete_code_exchange(credential, backend, params, opts)
      end
    end
  end

  @doc """
  Replaces a credential's secret material (new API key, re-pasted token).
  The previous version is retained by backends with `:secret_versions`.
  """
  def rotate(credential_id, payload, opts \\ []) do
    with {:ok, credential} <- fetch(credential_id),
         :ok <- ensure_status(credential, [:active, :expired, :reauth_required]),
         :ok <- ensure_kind(credential, SecretPayload.kind(payload)),
         backend = backend_for(credential),
         {:ok, external_ref} <- backend.put_secret(payload, ctx(credential)) do
      now = DateTime.utc_now(:second)

      {:ok, credential} =
        update_credential(credential, %{
          external_ref: external_ref,
          status: :active,
          rotated_at: now,
          expires_at: payload_expiry(payload)
        })

      TokenCache.invalidate(credential.id)
      record_event(credential, :rotated, opts[:actor] || "system", %{})
      {:ok, credential}
    end
  end

  @doc """
  Revokes a credential: best-effort upstream disconnect/deletion of material,
  then a permanent `:revoked` status. The metadata row and its events remain
  for audit.
  """
  def revoke(credential_id, opts \\ []) do
    with {:ok, credential} <- fetch(credential_id),
         :ok <- ensure_status_not(credential, :revoked) do
      backend = backend_for(credential)
      discard_material(backend, credential)

      {:ok, credential} = update_credential(credential, %{status: :revoked, external_ref: nil})
      TokenCache.invalidate(credential.id)
      record_event(credential, :revoked, opts[:actor] || "system", %{})
      {:ok, credential}
    end
  end

  @doc "Lists credentials visible to a scope, optionally filtered."
  def list(scope, filters \\ []) when is_map(scope) do
    Credential
    |> where([c], c.org_id == ^Map.fetch!(scope, :org_id))
    |> apply_filters(filters)
    |> order_by([c], desc: c.inserted_at)
    |> Repo.all()
  end

  @doc "Fetches a credential's metadata row."
  def fetch(credential_id) when is_binary(credential_id) do
    case Repo.get(Credential, credential_id) do
      nil -> {:error, :not_found}
      credential -> {:ok, credential}
    end
  end

  # --- Resolution ---

  @doc """
  Resolves a credential to its runtime auth shape.

  `requirements` may carry:

    * `:methods` — auth methods the caller accepts (e.g. `["oauth", "api_key"]`)
    * `:scopes` — OAuth scopes the caller needs (subset-checked for OAuth
      credentials, ignored for API keys)
    * `:scope` — tenancy scope (`%{org_id: ...}`) to enforce; omitted means
      no enforcement (single-tenant deployments)
    * `:actor` — audit attribution, e.g. `"run:" <> run_id`

  OAuth resolution is cache-first; a stale token triggers the single-flight
  refresh path (self-managed backends) or a fresh fetch (managed backends).
  A refresh rejected by the provider transitions the credential to
  `:reauth_required` — the caller gets an actionable error, never a silently
  dead token.
  """
  def resolve(credential_id, requirements \\ %{}) when is_binary(credential_id) do
    with {:ok, credential} <- fetch(credential_id),
         :ok <- check_tenancy(credential, requirements[:scope]),
         :ok <- ensure_status(credential, [:active]),
         :ok <- check_method(credential, requirements[:methods]),
         :ok <- check_scopes(credential, requirements[:scopes]) do
      do_resolve(credential, requirements[:actor] || "system")
    end
  end

  @doc """
  Legacy `Provider.fetch_token/2` shim: resolves a `%{"credential_id" => id}`
  reference to the flat token map older call sites expect. Returns
  `{:error, :unknown_credential}` when the id isn't in this system so callers
  can fall back to legacy stores.
  """
  def fetch_token(provider, ref, scopes) when is_binary(provider) and is_map(ref) do
    with {:ok, credential_id} <- ref_credential_id(ref),
         {:ok, resolved} <- resolve(credential_id, %{scopes: scopes}) do
      case resolved.auth do
        {:bearer, token} -> {:ok, %{access_token: token, expires_at: resolved.expires_at}}
        _other -> {:error, {:unsupported_auth_shape, provider}}
      end
    else
      :error -> {:error, :unknown_credential}
      {:error, :not_found} -> {:error, :unknown_credential}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_resolve(%Credential{kind: :oauth} = credential, actor) do
    case TokenCache.get(credential.id) do
      {:ok, %AccessToken{} = token} ->
        emit_telemetry(:accessed, credential, :cache_hit)
        {:ok, resolved_oauth(credential, token)}

      :miss ->
        backend = backend_for(credential)

        if Backend.capability?(backend, :managed_oauth) do
          resolve_managed_oauth(credential, backend, actor)
        else
          resolve_self_managed_oauth(credential, backend, actor)
        end
    end
  end

  defp do_resolve(%Credential{kind: kind} = credential, actor) when kind in [:api_key, :custom] do
    backend = backend_for(credential)

    case backend.get_secret(credential.external_ref, ctx(credential)) do
      {:ok, payload} ->
        with {:ok, auth} <- static_auth(credential, payload) do
          touch_last_used(credential)
          record_event(credential, :accessed, actor, %{})

          {:ok,
           %Resolved{
             credential_id: credential.id,
             provider: credential.provider,
             method: credential.method,
             auth: auth,
             scopes: credential.scopes
           }}
        end

      {:error, :not_found} ->
        flag_reauth_required(credential, actor, %{reason: "secret_material_missing"})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_managed_oauth(credential, backend, actor) do
    case backend.get_oauth_token(credential.external_ref, ctx(credential)) do
      {:ok, %AccessToken{} = token} ->
        cache_token(credential.id, token, @managed_cache_ttl_seconds)
        touch_last_used(credential)
        record_event(credential, :accessed, actor, %{backend: backend.id()})
        {:ok, resolved_oauth(credential, token)}

      {:error, :reauth_required} ->
        flag_reauth_required(credential, actor, %{reason: "backend_reported_reauth"})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_self_managed_oauth(credential, backend, actor) do
    result =
      Repo.transaction(fn ->
        advisory_lock!(credential.id)

        # Another resolver on this node may have refreshed while we waited.
        case TokenCache.get(credential.id) do
          {:ok, token} ->
            {token, :cache_hit}

          :miss ->
            with {:ok, payload} <- read_oauth_payload(backend, credential) do
              if token_fresh?(payload) do
                {access_token(payload), :accessed}
              else
                case refresh_oauth(credential, backend, payload) do
                  {:ok, token} -> {token, :refreshed}
                  {:error, reason} -> Repo.rollback(reason)
                end
              end
            else
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)

    case result do
      {:ok, {token, :cache_hit}} ->
        emit_telemetry(:accessed, credential, :cache_hit)
        {:ok, resolved_oauth(credential, token)}

      {:ok, {token, action}} ->
        cache_token(credential.id, token, @no_expiry_cache_ttl_seconds)
        touch_last_used(credential)
        record_event(credential, action, actor, %{})
        {:ok, resolved_oauth(credential, token)}

      {:error, :invalid_grant} ->
        flag_reauth_required(credential, actor, %{reason: "invalid_grant"})

      {:error, :not_found} ->
        flag_reauth_required(credential, actor, %{reason: "secret_material_missing"})

      {:error, :token_expired_no_refresh} ->
        {:ok, credential} = update_credential(credential, %{status: :expired})
        record_event(credential, :refresh_failed, actor, %{reason: "no_refresh_token"})
        {:error, :expired}

      {:error, reason} ->
        record_event(credential, :refresh_failed, actor, %{reason: inspect(reason)})
        {:error, {:refresh_failed, reason}}
    end
  end

  defp read_oauth_payload(backend, credential) do
    case backend.get_secret(credential.external_ref, ctx(credential)) do
      {:ok, %OAuthToken{} = payload} -> {:ok, payload}
      {:ok, _other} -> {:error, :not_oauth_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  # Exchanges the refresh token and persists the new payload BEFORE returning
  # it — with rotating refresh tokens (GitHub Apps), returning first and
  # persisting later risks orphaning the only valid refresh token on a crash.
  defp refresh_oauth(credential, backend, %OAuthToken{} = payload) do
    with {:ok, refresh_token} <- refreshable(payload),
         {:ok, oauth_spec} <- oauth_method_spec(credential.provider),
         {:ok, client} <- oauth_client(credential.provider),
         {:ok, body} <-
           token_request(oauth_spec[:token_url],
             grant_type: "refresh_token",
             refresh_token: refresh_token,
             client_id: client[:client_id],
             client_secret: client[:client_secret]
           ) do
      new_payload = %OAuthToken{
        access_token: body["access_token"],
        refresh_token: body["refresh_token"] || payload.refresh_token,
        expires_at: expires_at_from_body(body),
        scopes: scopes_from_body(body) || payload.scopes
      }

      with {:ok, _external_ref} <- backend.put_secret(new_payload, ctx(credential)) do
        {:ok, access_token(new_payload)}
      end
    end
  end

  defp refreshable(%OAuthToken{refresh_token: refresh_token})
       when is_binary(refresh_token) and refresh_token != "",
       do: {:ok, refresh_token}

  defp refreshable(_payload), do: {:error, :token_expired_no_refresh}

  # --- Connect flow internals ---

  defp connect_config(backend, credential, oauth_spec) do
    if Backend.capability?(backend, :managed_oauth) do
      backend.connect_config(credential.provider, ctx(credential))
    else
      with {:ok, client} <- oauth_client(credential.provider) do
        query =
          URI.encode_query(
            client_id: client[:client_id],
            redirect_uri: client[:redirect_uri],
            response_type: "code",
            scope: Enum.join(credential.scopes, " "),
            state: credential.id
          )

        {:ok,
         %{authorization_url: "#{oauth_spec[:authorize_url]}?#{query}", state: credential.id}}
      end
    end
  end

  defp complete_managed_connect(credential, params, opts) do
    case param(params, :external_ref) do
      external_ref when is_binary(external_ref) ->
        {:ok, credential} =
          update_credential(credential, %{
            status: :active,
            external_ref: external_ref,
            provider_metadata: param(params, :provider_metadata) || credential.provider_metadata
          })

        record_event(credential, :connected, opts[:actor] || "system", %{})
        {:ok, credential}

      _other ->
        {:error, :missing_external_ref}
    end
  end

  defp complete_code_exchange(credential, backend, params, opts) do
    with code when is_binary(code) <- param(params, :code) || {:error, :missing_code},
         {:ok, oauth_spec} <- oauth_method_spec(credential.provider),
         {:ok, client} <- oauth_client(credential.provider),
         {:ok, body} <-
           token_request(oauth_spec[:token_url],
             grant_type: "authorization_code",
             code: code,
             client_id: client[:client_id],
             client_secret: client[:client_secret],
             redirect_uri: client[:redirect_uri]
           ) do
      payload = %OAuthToken{
        access_token: body["access_token"],
        refresh_token: body["refresh_token"],
        expires_at: expires_at_from_body(body),
        scopes: scopes_from_body(body) || credential.scopes
      }

      with {:ok, external_ref} <- backend.put_secret(payload, ctx(credential)) do
        {:ok, credential} =
          update_credential(credential, %{
            status: :active,
            external_ref: external_ref,
            scopes: payload.scopes,
            expires_at: payload.expires_at
          })

        TokenCache.invalidate(credential.id)
        record_event(credential, :connected, opts[:actor] || "system", %{})
        {:ok, credential}
      end
    end
  end

  # --- Token endpoint client ---

  defp token_request(token_url, form) do
    req_opts = Keyword.get(config(), :req_options, [])

    request =
      Keyword.merge(
        [url: token_url, form: form, headers: [{"accept", "application/json"}]],
        req_opts
      )

    case Req.post(request) do
      {:ok, %Req.Response{status: status, body: %{"access_token" => token} = body}}
      when status in 200..299 and is_binary(token) ->
        {:ok, body}

      # Providers signal a dead grant either by status or, like GitHub, by an
      # error body on a 200.
      {:ok, %Req.Response{body: %{"error" => error}}}
      when error in ["invalid_grant", "bad_refresh_token", "bad_verification_code"] ->
        {:error, :invalid_grant}

      {:ok, %Req.Response{status: status}} when status in [400, 401] ->
        {:error, :invalid_grant}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:token_endpoint_status, status}}

      {:error, reason} ->
        {:error, {:token_endpoint_unreachable, reason}}
    end
  end

  defp expires_at_from_body(%{"expires_in" => expires_in}) when is_integer(expires_in) do
    DateTime.add(DateTime.utc_now(:second), expires_in, :second)
  end

  defp expires_at_from_body(_body), do: nil

  defp scopes_from_body(%{"scope" => scope}) when is_binary(scope) and scope != "" do
    String.split(scope, [" ", ","], trim: true)
  end

  defp scopes_from_body(_body), do: nil

  # --- Checks ---

  defp check_tenancy(_credential, nil), do: :ok

  defp check_tenancy(%Credential{org_id: org_id}, %{org_id: org_id}), do: :ok
  defp check_tenancy(_credential, _scope), do: {:error, :scope_mismatch}

  defp ensure_status(%Credential{status: status}, allowed) do
    if status in allowed, do: :ok, else: {:error, status_error(status)}
  end

  defp ensure_status_not(%Credential{status: status}, status), do: {:error, status_error(status)}
  defp ensure_status_not(_credential, _status), do: :ok

  defp status_error(:active), do: :already_active
  defp status_error(status), do: status

  defp ensure_kind(%Credential{kind: kind}, kind), do: :ok
  defp ensure_kind(%Credential{kind: kind}, other), do: {:error, {:kind_mismatch, kind, other}}

  defp check_method(_credential, nil), do: :ok
  defp check_method(_credential, []), do: :ok

  defp check_method(%Credential{method: method}, methods) do
    if method in Enum.map(methods, &to_string/1) do
      :ok
    else
      {:error, {:method_not_accepted, method}}
    end
  end

  # Scope requirements only constrain OAuth grants; an API key's reach is
  # whatever the provider gave it, so there's nothing to subset-check.
  defp check_scopes(%Credential{kind: :oauth, scopes: granted}, required)
       when is_list(required) and required != [] do
    case Enum.reject(required, &(&1 in granted)) do
      [] -> :ok
      missing -> {:error, {:missing_scopes, missing}}
    end
  end

  defp check_scopes(_credential, _required), do: :ok

  defp validate_method(provider, method) do
    case Provider.spec(provider) do
      {:ok, %{methods: methods}} ->
        if Enum.any?(methods, fn {name, _spec} -> Atom.to_string(name) == method end) do
          :ok
        else
          {:error, {:method_not_supported, provider, method}}
        end

      {:error, _no_spec} ->
        :ok
    end
  end

  defp oauth_method_spec(provider) do
    case Provider.spec(provider) do
      {:ok, %{methods: %{oauth: oauth_spec}}} -> {:ok, oauth_spec}
      {:ok, _spec} -> {:error, {:oauth_not_supported, provider}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Internals ---

  defp insert_with_secret(credential_attrs, payload, backend, actor) do
    changeset = Credential.changeset(%Credential{}, credential_attrs)

    Repo.transaction(fn ->
      with {:ok, credential} <- Repo.insert(changeset),
           {:ok, external_ref} <- backend.put_secret(payload, ctx(credential)),
           {:ok, credential} <- update_credential(credential, %{external_ref: external_ref}) do
        record_event(credential, :created, actor, %{})
        credential
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp discard_material(backend, %Credential{external_ref: nil}), do: backend

  defp discard_material(backend, credential) do
    managed_oauth? =
      credential.kind == :oauth and Backend.capability?(backend, :managed_oauth) and
        function_exported?(backend, :disconnect, 2)

    # Best-effort: upstream may already be gone; revocation proceeds locally
    # either way and the event records the attempt.
    if managed_oauth? do
      backend.disconnect(credential.external_ref, ctx(credential))
    else
      backend.delete_secret(credential.external_ref, ctx(credential))
    end
  end

  defp static_auth(%Credential{kind: :api_key} = credential, %SecretPayload.ApiKey{key: key}) do
    case api_key_auth_style(credential.provider) do
      :bearer -> {:ok, {:bearer, key}}
      {:header, name} -> {:ok, {:header, name, key}}
    end
  end

  defp static_auth(%Credential{kind: :custom}, %SecretPayload.Custom{fields: fields}) do
    {:ok, {:fields, fields}}
  end

  defp static_auth(%Credential{} = credential, _payload) do
    {:error, {:payload_kind_mismatch, credential.id}}
  end

  defp api_key_auth_style(provider) do
    case Provider.spec(provider) do
      {:ok, %{methods: %{api_key: %{auth: auth}}}} -> auth
      _other -> :bearer
    end
  end

  defp resolved_oauth(credential, %AccessToken{} = token) do
    %Resolved{
      credential_id: credential.id,
      provider: credential.provider,
      method: credential.method,
      auth: {:bearer, token.access_token},
      expires_at: token.expires_at,
      scopes: credential.scopes
    }
  end

  defp access_token(%OAuthToken{} = payload) do
    %AccessToken{
      access_token: payload.access_token,
      expires_at: payload.expires_at,
      scopes: payload.scopes
    }
  end

  defp token_fresh?(%OAuthToken{expires_at: nil}), do: true

  defp token_fresh?(%OAuthToken{expires_at: expires_at}) do
    threshold = DateTime.add(DateTime.utc_now(:second), @refresh_margin_seconds, :second)
    DateTime.compare(threshold, expires_at) == :lt
  end

  defp cache_token(credential_id, %AccessToken{} = token, default_ttl_seconds) do
    default_deadline = DateTime.add(DateTime.utc_now(:second), default_ttl_seconds, :second)

    stale_at =
      case token.expires_at do
        nil ->
          default_deadline

        expires_at ->
          earliest(default_deadline, DateTime.add(expires_at, -@refresh_margin_seconds, :second))
      end

    TokenCache.put(credential_id, token, stale_at)
  end

  defp earliest(a, b) do
    case DateTime.compare(a, b) do
      :gt -> b
      _other -> a
    end
  end

  defp flag_reauth_required(credential, actor, context) do
    {:ok, credential} = update_credential(credential, %{status: :reauth_required})
    TokenCache.invalidate(credential.id)
    record_event(credential, :reauth_required, actor, context)
    {:error, :reauth_required}
  end

  defp advisory_lock!(credential_id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
      @advisory_lock_namespace,
      :erlang.phash2(credential_id)
    ])
  end

  defp update_credential(credential, attrs) do
    credential
    |> Credential.changeset(attrs)
    |> Repo.update()
  end

  defp touch_last_used(credential) do
    Credential
    |> where([c], c.id == ^credential.id)
    |> Repo.update_all(set: [last_used_at: DateTime.utc_now(:second)])
  end

  defp record_event(credential, action, actor, context) do
    %CredentialEvent{}
    |> CredentialEvent.changeset(%{
      credential_id: credential.id,
      action: action,
      actor: actor,
      context: context
    })
    |> Repo.insert!()

    emit_telemetry(action, credential, :ok)
  end

  defp emit_telemetry(action, credential, outcome) do
    :telemetry.execute([:hermitscale, :credentials, action], %{count: 1}, %{
      credential_id: credential.id,
      provider: credential.provider,
      backend: credential.backend,
      outcome: outcome
    })
  end

  defp ctx(%Credential{} = credential) do
    %{
      credential_id: credential.id,
      provider: credential.provider,
      org_id: credential.org_id,
      user_id: credential.user_id,
      external_ref: credential.external_ref
    }
  end

  defp ref_credential_id(ref) do
    case Map.get(ref, "credential_id") || Map.get(ref, :credential_id) do
      credential_id when is_binary(credential_id) -> {:ok, credential_id}
      _other -> :error
    end
  end

  defp param(params, key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp payload_scopes(%OAuthToken{scopes: scopes}), do: scopes
  defp payload_scopes(_payload), do: []

  defp payload_expiry(%OAuthToken{expires_at: expires_at}), do: expires_at
  defp payload_expiry(_payload), do: nil

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:provider, provider}, query -> where(query, [c], c.provider == ^provider)
      {:status, status}, query -> where(query, [c], c.status == ^status)
      {:kind, kind}, query -> where(query, [c], c.kind == ^kind)
      _other, query -> query
    end)
  end

  # --- Backend registry ---

  @doc "The configured default backend module for new credentials."
  def default_backend do
    Keyword.fetch!(config(), :default_backend)
  end

  @doc "Resolves a credential's stored backend id to its module."
  def backend_for(%Credential{backend: backend_id}), do: backend_for(backend_id)

  def backend_for(backend_id) when is_binary(backend_id) do
    registry =
      Keyword.get(config(), :backends, @builtin_backends)
      |> Map.new(&{&1.id(), &1})

    Map.fetch!(registry, backend_id)
  end

  @doc "The default org used until a real tenancy model lands."
  def default_scope do
    %{org_id: Keyword.get(config(), :default_org_id, "default"), user_id: nil}
  end

  defp oauth_client(provider) do
    config()
    |> Keyword.get(:oauth_clients, %{})
    |> Map.get(provider)
    |> case do
      nil -> {:error, {:oauth_client_not_configured, provider}}
      client -> {:ok, client}
    end
  end

  defp config do
    Application.get_env(:hermitscale, __MODULE__, [])
  end
end
