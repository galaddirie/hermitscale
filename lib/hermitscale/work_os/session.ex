defmodule Hermitscale.WorkOS.Session do
  @moduledoc """
  WorkOS-bounded application session lifecycle.

  Every authenticated request verifies the encrypted WorkOS access JWT. Tokens
  near expiry refresh under a database row lock so rotating refresh tokens are
  never raced by concurrent requests.
  """

  import Ecto.Query

  alias Hermitscale.Accounts
  alias Hermitscale.Accounts.{Organization, OrganizationMembership, Scope, User}
  alias Hermitscale.Repo
  alias Hermitscale.WorkOS.{AuthSession, Client, JWT, TokenCipher}

  @handle_bytes 32
  @refresh_margin_seconds 60

  @doc """
  Verifies an authentication response before any local identity is created.
  """
  def verify_authentication(authentication) when is_map(authentication) do
    with {:ok, access_token} <- required_string(authentication, "access_token"),
         {:ok, refresh_token} <- required_string(authentication, "refresh_token"),
         {:ok, workos_user} <- required_map(authentication, "user"),
         {:ok, workos_user_id} <- required_string(workos_user, "id"),
         {:ok, claims} <- verify_token(access_token, subject: workos_user_id),
         {:ok, _workos_session_id} <- claim_string(claims, "sid"),
         {:ok, _expires_at} <- claims_expires_at(claims),
         {:ok, _authenticated_at} <- claims_authenticated_at(claims) do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: refresh_token,
         claims: claims,
         workos_user: workos_user
       }}
    end
  end

  @doc """
  Persists a previously verified WorkOS session and returns its opaque handle.
  """
  def create_verified(
        %User{workos_user_id: workos_user_id} = user,
        %{access_token: access_token, refresh_token: refresh_token, claims: claims}
      )
      when is_binary(workos_user_id) do
    with ^workos_user_id <- claims["sub"],
         {:ok, workos_session_id} <- claim_string(claims, "sid"),
         {:ok, expires_at} <- claims_expires_at(claims),
         {:ok, authenticated_at} <- claims_authenticated_at(claims),
         {:ok, organization} <- organization_from_claim(user, claims["org_id"]),
         {:ok, encryption_key_id, access_ciphertext} <- TokenCipher.encrypt(access_token),
         {:ok, ^encryption_key_id, refresh_ciphertext} <- TokenCipher.encrypt(refresh_token) do
      handle = random_handle()

      %AuthSession{}
      |> AuthSession.create_changeset(%{
        token_hash: token_hash(handle),
        user_id: user.id,
        org_id: organization.id,
        workos_session_id: workos_session_id,
        encryption_key_id: encryption_key_id,
        access_token_ciphertext: access_ciphertext,
        refresh_token_ciphertext: refresh_ciphertext,
        access_expires_at: expires_at,
        authenticated_at: authenticated_at
      })
      |> Repo.insert()
      |> case do
        {:ok, session} -> {:ok, %{handle: handle, session: session}}
        {:error, _changeset} = error -> error
      end
    else
      nil -> {:error, :organization_mapping_mismatch}
      {:error, _reason} = error -> error
      _mismatch when is_binary(workos_user_id) -> {:error, :identity_mismatch}
    end
  end

  @doc """
  Authenticates an opaque browser handle and hydrates the local `current_scope`.
  """
  def authenticate(handle, request_metadata \\ %{})

  def authenticate(handle, request_metadata) when is_binary(handle) do
    :telemetry.span([:hermitscale, :workos, :session, :authenticate], %{}, fn ->
      result = do_authenticate(handle, request_metadata)
      {result, %{result: result_class(result)}}
    end)
  end

  def authenticate(_handle, _request_metadata), do: {:error, :invalid_session}

  defp do_authenticate(handle, request_metadata) do
    with {:ok, session} <- load_active(handle),
         {:ok, session, claims} <- verify_or_refresh(session, request_metadata),
         {:ok, scope, user} <- hydrate_scope(session, claims) do
      {:ok, %{session: session, claims: claims, current_scope: scope, user: user}}
    end
  end

  @doc """
  Switches both the local organization and WorkOS token organization context.
  """
  def switch_organization(handle, %Scope{} = scope, organization_id, request_metadata \\ %{})
      when is_binary(handle) and is_binary(organization_id) do
    with {:ok, session} <- load_active(handle),
         true <- session.user_id == scope.user.id,
         %OrganizationMembership{organization: organization} <-
           Accounts.get_user_membership(scope.user, organization_id),
         :ok <- switchable_organization?(organization),
         {:ok, session, claims} <-
           refresh_locked(session, organization, request_metadata, true),
         {:ok, switched_scope, _user} <- hydrate_scope(session, claims) do
      {:ok, switched_scope}
    else
      false -> {:error, :unauthorized}
      nil -> {:error, :unauthorized}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Locally revokes a session and disconnects its LiveView socket.
  """
  def revoke(handle) when is_binary(handle) do
    with {:ok, session} <- load_by_handle(handle),
         {:ok, session} <- revoke_session_row(session) do
      disconnect(session)
      {:ok, session}
    end
  end

  @doc """
  Revokes all local rows matching a WorkOS `session.revoked` event.
  """
  def revoke_by_workos_session_id(workos_session_id) when is_binary(workos_session_id) do
    sessions =
      Repo.all(
        from session in AuthSession, where: session.workos_session_id == ^workos_session_id
      )

    Repo.transaction(fn ->
      Enum.each(sessions, fn session ->
        {:ok, revoked} = revoke_session_row(session)
        disconnect(revoked)
      end)

      length(sessions)
    end)
  end

  @doc """
  Revokes every local WorkOS session owned by a user.
  """
  def revoke_all_for_user(%User{} = user) do
    sessions = Repo.all(from session in AuthSession, where: session.user_id == ^user.id)

    revoke_sessions(sessions)
  end

  @doc """
  Revokes every local session for one user in an organization.

  Membership deactivation uses this to disconnect already-mounted LiveViews
  immediately instead of waiting for the next browser request to rehydrate
  `current_scope`.
  """
  def revoke_for_user_organization(user_id, organization_id)
      when is_integer(user_id) and is_binary(organization_id) do
    sessions =
      Repo.all(
        from session in AuthSession,
          where: session.user_id == ^user_id and session.org_id == ^organization_id
      )

    revoke_sessions(sessions)
  end

  @doc """
  Revokes every local session currently scoped to an organization.
  """
  def revoke_for_organization(organization_id) when is_binary(organization_id) do
    sessions =
      Repo.all(
        from session in AuthSession,
          where: session.org_id == ^organization_id
      )

    revoke_sessions(sessions)
  end

  @doc """
  Lists session identifiers for durable revocation and deletion cleanup.
  """
  def list_for_user(%User{} = user) do
    Repo.all(from session in AuthSession, where: session.user_id == ^user.id)
  end

  @doc """
  Clears local authority and returns the WorkOS browser logout URL.
  """
  def logout(handle, return_to \\ nil) when is_binary(handle) do
    with {:ok, session} <- revoke(handle) do
      {:ok, client().logout_url(session.workos_session_id, return_to)}
    end
  end

  @doc """
  Checks fresh-auth age for destructive settings actions.
  """
  def fresh?(%AuthSession{authenticated_at: authenticated_at}, max_age_minutes)
      when is_integer(max_age_minutes) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -max_age_minutes, :minute)
    DateTime.after?(authenticated_at, cutoff)
  end

  @doc """
  LiveView socket topic for a server-side session row.
  """
  def socket_topic(%AuthSession{id: id}), do: "workos_sessions:#{id}"

  defp load_active(handle) do
    with {:ok, session} <- load_by_handle(handle),
         nil <- session.revoked_at,
         nil <- session.user.deleted_at,
         nil <- session.user.deletion_pending_at do
      {:ok, session}
    else
      %DateTime{} -> {:error, :invalid_session}
      {:error, _reason} = error -> error
    end
  end

  defp load_by_handle(handle) do
    hash = token_hash(handle)

    case Repo.one(
           from session in AuthSession,
             where: session.token_hash == ^hash,
             preload: [:user]
         ) do
      %AuthSession{} = session ->
        case Plug.Crypto.secure_compare(session.token_hash, hash) do
          true -> {:ok, session}
          false -> {:error, :invalid_session}
        end

      nil ->
        {:error, :invalid_session}
    end
  end

  defp verify_or_refresh(session, request_metadata) do
    with {:ok, access_token} <-
           TokenCipher.decrypt(session.access_token_ciphertext, session.encryption_key_id),
         {:ok, claims} <-
           verify_token(access_token,
             subject: session.user.workos_user_id,
             session_id: session.workos_session_id,
             allow_expired: true
           ) do
      case refresh_required?(claims) do
        true ->
          organization = Repo.get!(Organization, session.org_id)
          refresh_locked(session, organization, request_metadata, false)

        false ->
          {:ok, session, claims}
      end
    else
      {:error, _reason} -> {:error, :invalid_session}
    end
  end

  defp refresh_locked(session, organization, request_metadata, force?) do
    Repo.transaction(fn ->
      locked =
        Repo.one!(
          from stored in AuthSession,
            where: stored.id == ^session.id,
            lock: "FOR UPDATE",
            preload: [:user]
        )

      case force? || refresh_required?(locked.access_expires_at) do
        true -> rotate_locked_session(locked, organization, request_metadata)
        false -> verify_committed_session(locked)
      end
    end)
    |> unwrap_transaction()
  end

  defp rotate_locked_session(session, organization, request_metadata) do
    with {:ok, refresh_token} <-
           TokenCipher.decrypt(session.refresh_token_ciphertext, session.encryption_key_id),
         {:ok, authentication} <-
           client().authenticate_with_refresh_token(
             refresh_token,
             organization.workos_organization_id,
             request_metadata
           ),
         {:ok, access_token} <- required_string(authentication, "access_token"),
         {:ok, replacement_refresh_token} <- required_string(authentication, "refresh_token"),
         {:ok, claims} <-
           verify_token(access_token,
             subject: session.user.workos_user_id,
             session_id: session.workos_session_id
           ),
         :ok <- validate_organization_claim(claims["org_id"], organization),
         {:ok, expires_at} <- claims_expires_at(claims),
         {:ok, encryption_key_id, access_ciphertext} <- TokenCipher.encrypt(access_token),
         {:ok, ^encryption_key_id, refresh_ciphertext} <-
           TokenCipher.encrypt(replacement_refresh_token),
         {:ok, session} <-
           session
           |> AuthSession.rotate_changeset(%{
             org_id: organization.id,
             encryption_key_id: encryption_key_id,
             access_token_ciphertext: access_ciphertext,
             refresh_token_ciphertext: refresh_ciphertext,
             access_expires_at: expires_at
           })
           |> Repo.update() do
      {:ok, session, claims}
    else
      {:error, :invalid_grant} ->
        {:ok, revoked} = revoke_session_row(session)
        disconnect(revoked)
        {:error, :invalid_session}

      {:error, reason} when reason in [:unavailable, :rate_limited] ->
        {:error, :unavailable}

      {:error, _reason} ->
        {:error, :invalid_session}
    end
  end

  defp verify_committed_session(session) do
    with {:ok, access_token} <-
           TokenCipher.decrypt(session.access_token_ciphertext, session.encryption_key_id),
         {:ok, claims} <-
           verify_token(access_token,
             subject: session.user.workos_user_id,
             session_id: session.workos_session_id
           ) do
      {:ok, session, claims}
    end
  end

  defp hydrate_scope(%AuthSession{} = session, claims) do
    user = %{session.user | authenticated_at: session.authenticated_at}
    {organization, membership} = Accounts.resolve_organization(user, session.org_id)

    with true <- organization.id == session.org_id,
         :ok <- validate_organization_claim(claims["org_id"], organization) do
      scope =
        user
        |> Scope.for_user()
        |> Scope.put_organization(organization, membership)

      {:ok, scope, user}
    else
      false -> {:error, :organization_mapping_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp organization_from_claim(user, nil) do
    {organization, _membership} = Accounts.resolve_organization(user, nil)

    case organization do
      %Organization{personal: true} -> {:ok, organization}
      _other -> {:error, :organization_mapping_mismatch}
    end
  end

  defp organization_from_claim(user, workos_organization_id)
       when is_binary(workos_organization_id) do
    with %Organization{} = organization <-
           Accounts.get_organization_by_workos_id(workos_organization_id),
         %OrganizationMembership{} <-
           Accounts.get_user_membership(user, organization.id),
         :ok <- switchable_organization?(organization) do
      {:ok, organization}
    else
      _other -> {:error, :organization_mapping_mismatch}
    end
  end

  defp switchable_organization?(%Organization{personal: true}), do: :ok

  defp switchable_organization?(%Organization{
         personal: false,
         provisioning_state: :ready,
         workos_organization_id: workos_organization_id
       })
       when is_binary(workos_organization_id),
       do: :ok

  defp switchable_organization?(_organization), do: {:error, :organization_unavailable}

  defp validate_organization_claim(nil, %Organization{personal: true}), do: :ok

  defp validate_organization_claim(
         workos_organization_id,
         %Organization{personal: false, workos_organization_id: workos_organization_id}
       )
       when is_binary(workos_organization_id),
       do: :ok

  defp validate_organization_claim(_claim, _organization),
    do: {:error, :organization_mapping_mismatch}

  defp refresh_required?(%DateTime{} = expiration) do
    expiration
    |> DateTime.compare(DateTime.add(DateTime.utc_now(:second), @refresh_margin_seconds, :second))
    |> Kernel.!=(:gt)
  end

  defp refresh_required?(%{"exp" => expiration}) when is_integer(expiration) do
    expiration <= System.system_time(:second) + @refresh_margin_seconds
  end

  defp revoke_session_row(%AuthSession{revoked_at: %DateTime{}} = session), do: {:ok, session}

  defp revoke_session_row(%AuthSession{} = session) do
    session
    |> AuthSession.revoke_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp revoke_sessions(sessions) do
    Repo.transaction(fn ->
      Enum.each(sessions, fn session ->
        {:ok, revoked} = revoke_session_row(session)
        disconnect(revoked)
      end)

      length(sessions)
    end)
  end

  defp disconnect(%AuthSession{} = session) do
    HermitscaleWeb.Endpoint.broadcast(socket_topic(session), "disconnect", %{})
  end

  defp verify_token(access_token, opts) do
    verifier = session_config()[:jwt_verifier] || JWT
    verifier.verify(access_token, opts)
  end

  defp claims_expires_at(%{"exp" => expiration}) when is_integer(expiration) do
    DateTime.from_unix(expiration)
  end

  defp claims_expires_at(_claims), do: {:error, :invalid_expiration}

  defp claims_authenticated_at(claims) do
    timestamp = claims["auth_time"] || claims["iat"]

    case timestamp do
      value when is_integer(value) -> DateTime.from_unix(value)
      _other -> {:error, :invalid_authentication_time}
    end
  end

  defp claim_string(claims, key) do
    case claims[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :invalid_access_token}
    end
  end

  defp required_string(map, key) do
    case fetch_value(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:invalid_authentication_response, key}}
    end
  end

  defp required_map(map, key) do
    case fetch_value(map, key) do
      value when is_map(value) -> {:ok, value}
      _other -> {:error, {:invalid_authentication_response, key}}
    end
  end

  defp fetch_value(map, "access_token"),
    do: Map.get(map, "access_token") || Map.get(map, :access_token)

  defp fetch_value(map, "refresh_token"),
    do: Map.get(map, "refresh_token") || Map.get(map, :refresh_token)

  defp fetch_value(map, "user"), do: Map.get(map, "user") || Map.get(map, :user)
  defp fetch_value(map, "id"), do: Map.get(map, "id") || Map.get(map, :id)

  defp unwrap_transaction({:ok, {:ok, session, claims}}), do: {:ok, session, claims}
  defp unwrap_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, _reason}), do: {:error, :unavailable}

  defp random_handle do
    @handle_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp token_hash(handle), do: :crypto.hash(:sha256, handle)

  defp client, do: session_config()[:client] || Client

  defp result_class({:ok, _authentication}), do: :ok
  defp result_class({:error, reason}), do: reason

  defp session_config do
    Application.get_env(:hermitscale, __MODULE__, [])
  end
end
