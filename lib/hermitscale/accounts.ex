defmodule Hermitscale.Accounts do
  @moduledoc "WorkOS-owned organization provisioning, collaboration and workspace discovery."
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Authorization
  alias Hermitscale.WorkOS.Client

  @doc "Idempotently provisions an ordinary organization and its owner membership."
  def ensure_personal_organization(%{id: "user_" <> _ = user_id} = user) do
    external_id = "personal:" <> user_id

    with {:ok, organization} <- ensure_organization(external_id, user),
         :ok <- ensure_owner_membership(user_id, organization["id"]) do
      {:ok, organization}
    end
  end

  defp ensure_organization(external_id, user) do
    case Client.adapter(__MODULE__).get_organization_by_external_id(external_id) do
      {:ok, org} ->
        {:ok, org}

      {:error, :not_found} ->
        case Client.adapter(__MODULE__).create_organization(%{
               "external_id" => external_id,
               "name" => workspace_name(user),
               "metadata" => %{"personal_owner_user_id" => user.id}
             }) do
          {:ok, org} ->
            {:ok, org}

          {:error, reason} when reason in [:conflict, :unprocessable, :unavailable] ->
            Client.adapter(__MODULE__).get_organization_by_external_id(external_id)

          error ->
            error
        end

      error ->
        error
    end
  end

  defp workspace_name(%{first_name: name}) when is_binary(name) and name != "",
    do: name <> "’s workspace"

  defp workspace_name(_user), do: "My workspace"

  defp ensure_owner_membership(user_id, org_id) do
    with {:ok, %{"data" => memberships}} <-
           Client.adapter(__MODULE__).list_memberships(user_id, org_id) do
      case Enum.find(memberships, &(&1["user_id"] == user_id and &1["organization_id"] == org_id)) do
        %{"status" => "active"} ->
          :ok

        nil ->
          case Client.adapter(__MODULE__).create_membership(user_id, org_id, "admin") do
            {:ok, _membership} -> :ok
            {:error, :conflict} -> ensure_owner_membership(user_id, org_id)
            error -> error
          end

        _ ->
          {:error, :membership_inactive}
      end
    end
  end

  @doc "Lists ordinary workspaces where the caller has active membership."
  def list_organizations(%Scope{user: %{id: user_id}}) do
    with {:ok, %{"data" => memberships}} <- Client.adapter(__MODULE__).list_memberships(user_id) do
      memberships
      |> Enum.filter(&(&1["user_id"] == user_id and &1["status"] == "active"))
      |> Enum.reduce_while({:ok, []}, fn membership, {:ok, orgs} ->
        case Client.adapter(__MODULE__).get_organization(membership["organization_id"]) do
          {:ok, org} -> {:cont, {:ok, orgs ++ [org]}}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc "Invites a member with Runner as the default, using the same rules for every organization."
  def invite(%Scope{} = scope, email, role \\ "runner") do
    with :ok <- Authorization.authorize(scope, "members:manage"),
         :ok <- validate_role(role) do
      Client.adapter(__MODULE__).invite_member(
        Scope.organization_id!(scope),
        scope.user.id,
        email,
        role
      )
    end
  end

  def assign_role(%Scope{} = scope, membership_id, role) do
    with :ok <- Authorization.authorize(scope, "members:manage"),
         :ok <- validate_role(role),
         :ok <- same_membership_org(scope, membership_id) do
      Client.adapter(__MODULE__).update_membership(membership_id, role)
    end
  end

  def remove_member(%Scope{} = scope, membership_id) do
    with :ok <- Authorization.authorize(scope, "members:manage"),
         :ok <- same_membership_org(scope, membership_id) do
      Client.adapter(__MODULE__).remove_membership(membership_id)
    end
  end

  defp same_membership_org(scope, id) do
    org_id = Scope.organization_id!(scope)

    with {:ok, membership} <- Client.adapter(__MODULE__).get_membership(id) do
      case membership["organization_id"] == org_id do
        true -> :ok
        false -> {:error, :forbidden}
      end
    end
  end

  defp validate_role(role) when role in ~w(admin editor runner), do: :ok
  defp validate_role(_role), do: {:error, :invalid_role}
end
