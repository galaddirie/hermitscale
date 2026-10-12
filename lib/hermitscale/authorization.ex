defmodule Hermitscale.Authorization do
  @moduledoc "Organization action authorization from verified WorkOS permission claims."
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Integrations.ExecutionContext
  alias Hermitscale.WorkOS.Client

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

  @doc "Checks an execution actor's current membership and permissions through WorkOS."
  def execution_scope(%ExecutionContext{
        organization_id: "org_" <> _ = org_id,
        actor_user_id: "user_" <> _ = user_id,
        required_permissions: permissions
      }) do
    with {:ok, %{"data" => memberships}} <-
           Client.adapter(__MODULE__).list_memberships(user_id, org_id),
         %{
           "user_id" => ^user_id,
           "organization_id" => ^org_id,
           "status" => "active",
           "role" => %{"slug" => slug}
         } <-
           Enum.find(memberships, &(&1["user_id"] == user_id and &1["organization_id"] == org_id)),
         {:ok, %{"permissions" => granted}} <- Client.adapter(__MODULE__).get_role(slug),
         scope =
           Scope.from_workos(%{id: user_id}, %{
             "sub" => user_id,
             "org_id" => org_id,
             "role" => slug,
             "permissions" => granted
           }),
         true <- Enum.all?(permissions, &(authorize(scope, &1) == :ok)) do
      {:ok, scope}
    else
      {:error, reason} when reason in [:unavailable, :rate_limited] -> {:error, reason}
      _ -> {:error, :execution_actor_ineligible}
    end
  end

  def execution_scope(_context), do: {:error, :execution_actor_ineligible}
end
