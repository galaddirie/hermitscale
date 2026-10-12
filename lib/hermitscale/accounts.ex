defmodule Hermitscale.Accounts do
  @moduledoc "Organization provisioning, collaboration and workspace discovery through the configured auth provider."
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Auth
  alias Hermitscale.Authorization

  @doc "Idempotently provisions an ordinary organization and its owner membership."
  def ensure_personal_organization(%{id: user_id} = user)
      when is_binary(user_id) and user_id != "" do
    external_id = "personal:" <> user_id

    with {:ok, organization} <- ensure_organization(external_id, user),
         :ok <- ensure_owner_membership(user_id, organization.id) do
      {:ok, organization}
    end
  end

  defp ensure_organization(external_id, user) do
    case Auth.get_organization_by_external_id(external_id) do
      {:ok, org} ->
        {:ok, org}

      {:error, :not_found} ->
        case Auth.create_organization(%{
               external_id: external_id,
               name: workspace_name(user),
               metadata: %{"personal_owner_user_id" => user.id}
             }) do
          {:ok, org} ->
            {:ok, org}

          {:error, reason} when reason in [:conflict, :unprocessable, :unavailable] ->
            Auth.get_organization_by_external_id(external_id)

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp workspace_name(%{first_name: name}) when is_binary(name) and name != "",
    do: name <> "’s workspace"

  defp workspace_name(_user), do: "My workspace"

  defp ensure_owner_membership(user_id, org_id) do
    with {:ok, membership} <- owner_membership(user_id, org_id) do
      case membership do
        %{status: "active"} -> :ok
        nil -> create_owner_membership(user_id, org_id)
        %{} -> {:error, :membership_inactive}
      end
    end
  end

  defp owner_membership(user_id, org_id) do
    with {:ok, memberships} <- Auth.list_memberships(user_id, org_id) do
      {:ok, Enum.find(memberships, &(&1.user_id == user_id and &1.org_id == org_id))}
    end
  end

  defp create_owner_membership(user_id, org_id) do
    case Auth.create_membership(user_id, org_id, "admin") do
      {:ok, _membership} -> :ok
      {:error, :conflict} -> resolve_membership_conflict(user_id, org_id)
      {:error, _reason} = error -> error
    end
  end

  defp resolve_membership_conflict(user_id, org_id) do
    with {:ok, membership} <- owner_membership(user_id, org_id) do
      case membership do
        %{status: "active"} -> :ok
        nil -> {:error, :conflict}
        %{} -> {:error, :membership_inactive}
      end
    end
  end

  @doc "Lists ordinary workspaces where the caller has active membership."
  def list_organizations(%Scope{user: %{id: user_id}}) do
    with {:ok, memberships} <- Auth.list_memberships(user_id),
         {:ok, organizations} <- fetch_organizations(memberships, user_id) do
      {:ok, Enum.reverse(organizations)}
    end
  end

  defp fetch_organizations(memberships, user_id) do
    memberships
    |> Enum.filter(&(&1.user_id == user_id and &1.status == "active"))
    |> Enum.reduce_while({:ok, []}, fn membership, {:ok, organizations} ->
      case Auth.get_organization(membership.org_id) do
        {:ok, organization} -> {:cont, {:ok, [organization | organizations]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc "Invites a member with Runner as the default, using the same rules for every organization."
  def invite(%Scope{} = scope, email, role \\ "runner") do
    with :ok <- Authorization.authorize(scope, "members:manage"),
         :ok <- validate_role(role) do
      Auth.invite_member(
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
      Auth.update_membership(membership_id, role)
    end
  end

  def remove_member(%Scope{} = scope, membership_id) do
    with :ok <- Authorization.authorize(scope, "members:manage"),
         :ok <- same_membership_org(scope, membership_id) do
      Auth.remove_membership(membership_id)
    end
  end

  defp same_membership_org(scope, id) do
    org_id = Scope.organization_id!(scope)

    with {:ok, membership} <- Auth.get_membership(id) do
      case membership.org_id == org_id do
        true -> :ok
        false -> {:error, :forbidden}
      end
    end
  end

  defp validate_role(role) when role in ~w(admin editor runner), do: :ok
  defp validate_role(_role), do: {:error, :invalid_role}
end
