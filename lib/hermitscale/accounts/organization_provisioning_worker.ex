defmodule Hermitscale.Accounts.OrganizationProvisioningWorker do
  @moduledoc """
  Idempotently mirrors a local shared organization and its creator membership
  into WorkOS.

  Retries first look up the organization by the stable local external ID, so a
  timeout after a successful remote create cannot produce a second mapping.
  """

  use Oban.Worker,
    queue: :workos,
    max_attempts: 12,
    unique: [
      period: :infinity,
      fields: [:args],
      keys: [:organization_id],
      states: :incomplete
    ]

  alias Hermitscale.Accounts
  alias Hermitscale.Accounts.{Organization, OrganizationMembership, User}
  alias Hermitscale.Repo
  alias Hermitscale.WorkOS.Client

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args: %{
            "organization_id" => organization_id,
            "owner_user_id" => owner_user_id
          }
        } = job
      ) do
    with %Organization{personal: false} = organization <-
           Repo.get(Organization, organization_id),
         %User{} = owner <- Repo.get(User, owner_user_id),
         :ok <- owner_available?(owner),
         {:ok, remote_organization} <- ensure_remote_organization(organization),
         {:ok, organization} <-
           Accounts.sync_workos_organization(remote_organization, :upsert),
         {:ok, _membership} <- ensure_owner_membership(organization, owner) do
      :telemetry.execute(
        [:hermitscale, :workos, :organization, :provisioned],
        %{count: 1},
        %{organization_id: organization.id}
      )

      :ok
    else
      nil ->
        :ok

      %Organization{personal: true} ->
        :ok

      {:error, reason} ->
        maybe_mark_unavailable(job, organization_id)
        {:error, reason}
    end
  end

  defp ensure_remote_organization(%Organization{} = organization) do
    case client().get_organization_by_external_id(organization.id) do
      {:ok, remote_organization} ->
        {:ok, remote_organization}

      {:error, :not_found} ->
        create_or_refetch_organization(organization)

      {:error, reason} ->
        {:error, {:organization_lookup_failed, reason}}
    end
  end

  defp create_or_refetch_organization(organization) do
    case client().create_organization(organization.name, organization.id) do
      {:ok, remote_organization} ->
        {:ok, remote_organization}

      {:error, :conflict} ->
        client().get_organization_by_external_id(organization.id)

      {:error, reason} ->
        {:error, {:organization_create_failed, reason}}
    end
  end

  defp ensure_owner_membership(organization, owner) do
    membership =
      Repo.get_by!(OrganizationMembership,
        org_id: organization.id,
        user_id: owner.id
      )

    case membership.workos_membership_id do
      membership_id when is_binary(membership_id) ->
        {:ok, membership}

      nil ->
        find_or_create_owner_membership(organization, owner)
    end
  end

  defp find_or_create_owner_membership(organization, owner) do
    case find_remote_membership(organization.workos_organization_id, owner.workos_user_id) do
      {:ok, nil} ->
        create_owner_membership(organization, owner)

      {:ok, remote_membership} ->
        Accounts.sync_workos_membership(remote_membership, :upsert)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_owner_membership(organization, owner) do
    case client().create_organization_membership(
           organization.workos_organization_id,
           owner.workos_user_id,
           "owner"
         ) do
      {:ok, remote_membership} ->
        Accounts.sync_workos_membership(remote_membership, :upsert)

      {:error, :conflict} ->
        with {:ok, remote_membership} when is_map(remote_membership) <-
               find_remote_membership(
                 organization.workos_organization_id,
                 owner.workos_user_id
               ) do
          Accounts.sync_workos_membership(remote_membership, :upsert)
        else
          {:ok, nil} -> {:error, :membership_conflict_without_mapping}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:membership_create_failed, reason}}
    end
  end

  defp find_remote_membership(organization_id, user_id) do
    do_find_remote_membership(organization_id, user_id, nil)
  end

  defp do_find_remote_membership(organization_id, user_id, cursor) do
    case client().list_organization_memberships(organization_id, cursor) do
      {:ok, %{"data" => memberships} = response} when is_list(memberships) ->
        case Enum.find(memberships, &(&1["user_id"] == user_id)) do
          nil ->
            case get_in(response, ["list_metadata", "after"]) do
              next when is_binary(next) and next != "" and next != cursor ->
                do_find_remote_membership(organization_id, user_id, next)

              _end ->
                {:ok, nil}
            end

          membership ->
            {:ok, membership}
        end

      {:ok, _invalid_response} ->
        {:error, :invalid_memberships_response}

      {:error, reason} ->
        {:error, {:membership_lookup_failed, reason}}
    end
  end

  defp owner_available?(%User{
         workos_user_id: workos_user_id,
         deletion_pending_at: nil,
         deleted_at: nil
       })
       when is_binary(workos_user_id),
       do: :ok

  defp owner_available?(_owner), do: {:error, :owner_unavailable}

  defp maybe_mark_unavailable(
         %Oban.Job{attempt: attempt, max_attempts: max_attempts},
         organization_id
       )
       when attempt >= max_attempts do
    case Repo.get(Organization, organization_id) do
      %Organization{} = organization ->
        Accounts.mark_organization_provisioning_failed(organization)

      nil ->
        :ok
    end
  end

  defp maybe_mark_unavailable(_job, _organization_id), do: :ok

  defp client do
    Application.get_env(:hermitscale, __MODULE__, [])[:client] || Client
  end
end
