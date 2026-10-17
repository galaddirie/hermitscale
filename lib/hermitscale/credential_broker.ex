defmodule Hermitscale.CredentialBroker do
  @moduledoc """
  Lets code in a workspace call provider APIs and Git hosts with the
  organization's connected accounts, without any provider credential entering
  the Sprite. See `docs/adr/0001-broker-workspace-credentials.md`.

  A grant attaches one connected account per provider to a workspace and lists
  the requests it allows (see `Hermitscale.CredentialBroker.Grant`). A broker
  token identifies a workspace and the member acting through it. Only the
  token's SHA-256 hash is stored, and the secret is returned once.

  Every brokered request re-checks the token, grant, and rule.
  `Hermitscale.Integrations.ConnectedAccounts.vend/1` then re-checks the actor's
  membership and the account immediately before the upstream request.
  """

  import Ecto.Query

  alias Hermitscale.Authorization
  alias Hermitscale.CredentialBroker.{Grant, Token}

  alias Hermitscale.Integrations.{
    ConnectedAccounts,
    CredentialRef,
    ExecutionContext,
    Provider,
    Request
  }

  alias Hermitscale.Repo
  alias Hermitscale.Workspaces

  @token_prefix "hsb_"
  @default_ttl 60 * 60
  @max_ttl 24 * 60 * 60

  @doc "Lists a workspace's grants."
  def list_grants(scope, workspace_reference) do
    with {:ok, workspace} <- Workspaces.fetch_workspace(scope, workspace_reference) do
      grants =
        Grant
        |> where([grant], grant.workspace_id == ^workspace.id)
        |> order_by([grant], asc: grant.provider)
        |> Repo.all()

      {:ok, grants}
    end
  end

  @doc """
  Creates or replaces the workspace's grant for a provider. Accepts `provider`,
  `account_id` (an organization connected account), and `rules`. Requires
  `connections:manage`.
  """
  def put_grant(scope, workspace_reference, attrs) do
    with :ok <- Authorization.authorize(scope, "connections:manage"),
         {:ok, workspace} <- Workspaces.fetch_workspace(scope, workspace_reference) do
      changeset =
        %Grant{
          id: Ecto.UUID.generate(),
          workspace_id: workspace.id,
          org_id: workspace.org_id,
          created_by_user_id: scope.user.id
        }
        |> Grant.changeset(attrs)

      with {:ok, grant} <- Ecto.Changeset.apply_action(changeset, :insert),
           :ok <- verify_account(scope, grant) do
        Repo.insert(changeset,
          on_conflict: {:replace, [:account_id, :rules, :created_by_user_id, :updated_at]},
          conflict_target: [:workspace_id, :provider],
          returning: true
        )
      end
    end
  end

  @doc "Removes the workspace's grant for a provider. Requires `connections:manage`."
  def delete_grant(scope, workspace_reference, provider) do
    with :ok <- Authorization.authorize(scope, "connections:manage"),
         {:ok, workspace} <- Workspaces.fetch_workspace(scope, workspace_reference) do
      case Repo.get_by(Grant, workspace_id: workspace.id, provider: provider) do
        nil -> {:error, :not_found}
        grant -> Repo.delete(grant)
      end
    end
  end

  @doc """
  Issues a broker token for the workspace, acting as the caller. Accepts `:ttl`
  in seconds (default one hour, at most 24 hours).

  Returns `{:ok, secret, token}`. The secret is not stored and cannot be
  retrieved again.
  """
  def issue_token(scope, workspace_reference, opts \\ []) do
    case Keyword.get(opts, :ttl, @default_ttl) do
      ttl when is_integer(ttl) and ttl > 0 and ttl <= @max_ttl ->
        with {:ok, workspace} <- Workspaces.fetch_workspace(scope, workspace_reference) do
          secret =
            @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

          %Token{
            id: Ecto.UUID.generate(),
            workspace_id: workspace.id,
            org_id: workspace.org_id,
            actor_user_id: scope.user.id,
            token_hash: hash(secret),
            expires_at: DateTime.add(DateTime.utc_now(:second), ttl)
          }
          |> Ecto.Changeset.change()
          |> Repo.insert()
          |> case do
            {:ok, token} -> {:ok, secret, token}
            {:error, _changeset} = error -> error
          end
        end

      _invalid ->
        {:error, :invalid_ttl}
    end
  end

  @doc "Revokes a broker token in the caller's organization."
  def revoke_token(scope, token_id) do
    with :ok <- Authorization.authorize(scope, "workflows:run") do
      now = DateTime.utc_now(:second)

      Token
      |> where([token], token.id == ^token_id and token.org_id == ^scope.organization.id)
      |> where([token], is_nil(token.revoked_at))
      |> Repo.update_all(set: [revoked_at: now, updated_at: now])
      |> case do
        {1, _rows} -> :ok
        {0, _rows} -> {:error, :not_found}
      end
    end
  end

  @doc """
  Environment for a command in the workspace. Pass it as the command's `:env`,
  never write it to the Sprite's disk.
  """
  def env(secret) when is_binary(secret),
    do: %{"HERMITSCALE_BROKER_URL" => url(), "HERMITSCALE_BROKER_TOKEN" => secret}

  @doc "The broker's base URL as seen from a Sprite."
  def url do
    Application.get_env(:hermitscale, __MODULE__, [])[:url] ||
      HermitscaleWeb.Endpoint.url() <> "/broker/v1"
  end

  @doc """
  Authorizes a brokered request. `method` is the HTTP method, or `FETCH` or
  `PUSH` for Git. `path` is the decoded provider path (`/owner/repo` for Git).

  Returns `{:ok, access}` with the token, grant, and a credential reference
  for the acting member.
  """
  def authorize(secret, provider, method, path) do
    with {:ok, token} <- fetch_token(secret),
         {:ok, grant} <- fetch_grant(token, provider),
         :ok <- allow(grant, method, path) do
      {:ok,
       %{
         token: token,
         grant: grant,
         ref: %CredentialRef{
           execution_context: %ExecutionContext{
             organization_id: token.org_id,
             actor_user_id: token.actor_user_id
           },
           provider_id: grant.provider,
           account_id: grant.account_id,
           required_scopes: []
         }
       }}
    end
  end

  @doc """
  Sends an authorized API request to the provider's API host. The response
  body is undecoded, and any echoed credential is redacted.
  """
  def request(%{ref: ref}, method, segments, query, headers, body) do
    with {:ok, %{destinations: [host | _]}} <- Provider.descriptor(ref.provider_id) do
      opts =
        Keyword.merge(req_options(),
          headers: headers,
          body: if(body == "", do: nil, else: body),
          decode_body: false
        )

      Request.request(method, upstream_url(host, segments, query), ref, opts)
    end
  end

  @doc """
  Sends an authorized Git smart-HTTP request to the provider's Git host. The
  response body is a `Req.Response.Async` stream owned by the caller.
  """
  def git_request(%{ref: ref}, method, segments, query, headers, body) do
    with {:ok, descriptor} <- Provider.descriptor(ref.provider_id),
         {:ok, host} <- git_host(descriptor),
         {:ok, credential} <- ConnectedAccounts.vend(ref) do
      basic = Base.encode64("x-access-token:" <> credential.value)

      [
        method: method,
        url: upstream_url(host, segments, query),
        headers: [{"authorization", "Basic " <> basic} | headers],
        body: body,
        into: :self,
        raw: true,
        compressed: false,
        redirect: false,
        retry: false,
        receive_timeout: 120_000
      ]
      |> Keyword.merge(req_options())
      |> Req.request()
      |> case do
        {:ok, response} -> {:ok, response}
        {:error, _exception} -> {:error, :provider_unavailable}
      end
    end
  end

  defp verify_account(scope, %Grant{provider: provider, account_id: account_id}) do
    with {:ok, _descriptor} <- Provider.descriptor(provider),
         {:ok, accounts} <- ConnectedAccounts.list(scope) do
      case Enum.any?(accounts, &(&1["provider"] == provider and &1["id"] == account_id)) do
        true -> :ok
        false -> {:error, :account_not_found}
      end
    end
  end

  defp fetch_token(@token_prefix <> _rest = secret) do
    now = DateTime.utc_now()

    Token
    |> join(:inner, [token], workspace in assoc(token, :workspace),
      on: workspace.org_id == token.org_id
    )
    |> where([token], token.token_hash == ^hash(secret))
    |> where([token], is_nil(token.revoked_at) and token.expires_at > ^now)
    |> Repo.one()
    |> case do
      nil -> {:error, :unauthorized}
      token -> {:ok, token}
    end
  end

  defp fetch_token(_secret), do: {:error, :unauthorized}

  defp fetch_grant(token, provider) do
    case Repo.get_by(Grant,
           workspace_id: token.workspace_id,
           org_id: token.org_id,
           provider: provider
         ) do
      nil -> {:error, :not_granted}
      grant -> {:ok, grant}
    end
  end

  defp allow(grant, method, path) do
    case Grant.allows?(grant, method, path) do
      true -> :ok
      false -> {:error, :endpoint_not_allowed}
    end
  end

  defp git_host(%{git_host: host}), do: {:ok, host}
  defp git_host(_descriptor), do: {:error, :git_unsupported}

  defp upstream_url(host, segments, query) do
    path =
      Enum.map_join(segments, "/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)

    url = "https://" <> host <> "/" <> path

    case query do
      "" -> url
      query -> url <> "?" <> query
    end
  end

  defp hash(secret), do: :crypto.hash(:sha256, secret)

  defp req_options, do: Application.get_env(:hermitscale, __MODULE__, [])[:req_options] || []
end
