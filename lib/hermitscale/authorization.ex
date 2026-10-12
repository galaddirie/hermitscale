defmodule Hermitscale.Authorization do
  @moduledoc "Organization action authorization from verified provider permissions."
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Auth
  alias Hermitscale.Integrations.ExecutionContext

  @doc "Checks both membership integrity and the requested permission slug."
  def authorize(
        %Scope{
          user: %{id: user_id},
          organization: %{id: org_id},
          membership: %{user_id: user_id, org_id: org_id, permissions: permissions} = membership
        },
        permission
      )
      when is_list(permissions) do
    case Map.get(membership, :status, :active) in [:active, "active"] and
           permission in permissions do
      true -> :ok
      false -> {:error, :forbidden}
    end
  end

  def authorize(_scope, _permission), do: {:error, :forbidden}

  @doc "Checks an execution actor's current membership and permissions through the auth provider."
  def execution_scope(%ExecutionContext{
        organization_id: org_id,
        actor_user_id: user_id,
        required_permissions: permissions
      })
      when is_binary(org_id) and org_id != "" and is_binary(user_id) and user_id != "" do
    with {:ok, memberships} <- Auth.list_memberships(user_id, org_id),
         %{user_id: ^user_id, org_id: ^org_id, status: "active", role: slug} = membership
         when is_binary(slug) and slug != "" <-
           Enum.find(memberships, &(&1.user_id == user_id and &1.org_id == org_id)),
         {:ok, %{permissions: granted}} <- Auth.get_role(slug),
         scope =
           %{id: user_id}
           |> Scope.for_user()
           |> Scope.put_organization(%{id: org_id}, Map.put(membership, :permissions, granted)),
         true <- Enum.all?(permissions, &(authorize(scope, &1) == :ok)) do
      {:ok, scope}
    else
      {:error, reason} = error when reason in [:unavailable, :rate_limited, :invalid_response] ->
        error

      {:error, _reason} ->
        {:error, :execution_actor_ineligible}

      nil ->
        {:error, :execution_actor_ineligible}

      %{} ->
        {:error, :execution_actor_ineligible}

      false ->
        {:error, :execution_actor_ineligible}
    end
  end

  def execution_scope(_context), do: {:error, :execution_actor_ineligible}
end
