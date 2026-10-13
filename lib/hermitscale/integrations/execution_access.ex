defmodule Hermitscale.Integrations.ExecutionAccess do
  @moduledoc "Scoped product capabilities and authorized provider credential selection."
  import Ecto.Query
  alias Hermitscale.{Authorization, Repo}
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Integrations.{Capability, ConnectedAccounts}

  @product_actions ~w(workflows.list workflows.inspect workflows.validate workflows.create runs.start runs.status agents.inspect agents.continue agents.cancel agents.publish apps.inspect apps.create apps.build apps.preview apps.logs apps.publish)

  def issue_product(scope, resources, actions, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_seconds, 3600)

    with true <- is_list(resources) and Enum.all?(resources, &is_binary/1),
         true <- is_list(actions) and Enum.all?(actions, &(&1 in @product_actions)),
         true <- is_integer(ttl) and ttl in 1..7200,
         :ok <- authorize_actions(scope, actions) do
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      %Capability{
        org_id: Scope.organization_id!(scope),
        actor_user_id: scope.user.id,
        token_digest: digest(token),
        expires_at: DateTime.add(DateTime.utc_now(:second), ttl)
      }
      |> Capability.changeset(%{
        kind: "product",
        resource_ids: resources,
        actions: actions,
        remaining_calls: Keyword.get(opts, :max_calls, 50)
      })
      |> Repo.insert()
      |> case do
        {:ok, record} -> {:ok, %{record: record, token: token}}
        {:error, _reason} = error -> error
      end
    else
      false -> {:error, :invalid_product_capability}
      {:error, _reason} = error -> error
    end
  end

  def authenticate(token, kind, action, resource_id \\ nil)

  def authenticate(token, "product", action, resource_id) when is_binary(token) do
    case Repo.get_by(Capability, token_digest: digest(token), kind: "product") do
      nil ->
        {:error, :invalid_capability}

      cap ->
        with :ok <- validate(cap, action, resource_id),
             {:ok, scope} <-
               Authorization.execution_scope(%Hermitscale.Integrations.ExecutionContext{
                 organization_id: cap.org_id,
                 actor_user_id: cap.actor_user_id,
                 required_permissions: []
               }) do
          {:ok, scope, cap}
        end
    end
  end

  def authenticate(_token, _kind, _action, _resource_id), do: {:error, :invalid_capability}

  def consume(cap) do
    Repo.transaction(fn ->
      current = Repo.one!(from c in Capability, where: c.id == ^cap.id, lock: "FOR UPDATE")

      case validate(current, "protocol", nil) do
        :ok ->
          current
          |> Ecto.Changeset.change(remaining_calls: current.remaining_calls - 1)
          |> Repo.update!()

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  def revoke(scope, capability_id) do
    org = Scope.organization_id!(scope)

    Repo.update_all(
      from(c in Capability,
        where: c.id == ^capability_id and c.org_id == ^org and c.actor_user_id == ^scope.user.id
      ),
      set: [revoked_at: DateTime.utc_now(:second)]
    )

    :ok
  end

  def provider_env(scope, session) do
    with {:ok, %{auth_method: "api_key", value: key}} <-
           credential(scope, session, "openai", []) do
      {:ok, %{"OPENAI_API_KEY" => key}}
    else
      {:ok, _credential} -> {:error, :unsupported_auth_method}
      {:error, _reason} = error -> error
    end
  end

  def credential(scope, session, provider, scopes, permissions \\ ["agents:run"]) do
    with {:ok, selection} <- selected(scope, session.connection_set, provider, scopes),
         {:ok, ref} <-
           ConnectedAccounts.credential_ref(
             Scope.execution_context(scope, permissions),
             selection,
             scopes
           ),
         {:ok, credential} <- ConnectedAccounts.vend(ref) do
      {:ok, credential}
    end
  end

  defp selected(scope, set, provider, scopes) do
    case Map.fetch(set, provider) do
      {:ok, selection} ->
        with :ok <- ConnectedAccounts.validate_selection(selection, provider),
             do: {:ok, selection}

      :error ->
        ConnectedAccounts.select(scope, provider, scopes)
    end
  end

  defp validate(cap, action, resource) do
    cond do
      cap.revoked_at != nil ->
        {:error, :capability_revoked}

      DateTime.compare(cap.expires_at, DateTime.utc_now(:second)) != :gt ->
        {:error, :capability_expired}

      action not in cap.actions and action != "protocol" ->
        {:error, :capability_action_denied}

      action != "protocol" and Hermitscale.ProductTools.resource_required?(action) and
          not is_binary(resource) ->
        {:error, :capability_resource_denied}

      resource != nil and resource not in cap.resource_ids ->
        {:error, :capability_resource_denied}

      cap.remaining_calls <= 0 ->
        {:error, :execution_budget_exceeded}

      true ->
        :ok
    end
  end

  defp authorize_actions(scope, actions) do
    Enum.reduce_while(actions, :ok, fn action, :ok ->
      case Authorization.authorize(scope, Hermitscale.ProductTools.permission(action)) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp digest(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
end
