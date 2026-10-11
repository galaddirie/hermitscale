defmodule Hermitscale.Accounts.OrganizationProvisioningWorkerTest do
  use Hermitscale.DataCase, async: false

  alias Hermitscale.Accounts

  alias Hermitscale.Accounts.{
    Organization,
    OrganizationMembership,
    OrganizationProvisioningWorker
  }

  alias Hermitscale.Repo
  alias Hermitscale.WorkOSTest.Client

  import Hermitscale.AccountsFixtures

  setup do
    start_supervised!({Client, %{}})

    previous_accounts = Application.get_env(:hermitscale, Accounts, [])
    previous_worker = Application.get_env(:hermitscale, OrganizationProvisioningWorker, [])

    Application.put_env(
      :hermitscale,
      Accounts,
      Keyword.put(previous_accounts, :workos_client, Client)
    )

    Application.put_env(
      :hermitscale,
      OrganizationProvisioningWorker,
      Keyword.put(previous_worker, :client, Client)
    )

    on_exit(fn ->
      Application.put_env(:hermitscale, Accounts, previous_accounts)
      Application.put_env(:hermitscale, OrganizationProvisioningWorker, previous_worker)
    end)
  end

  test "creates the local tenancy record before provisioning its WorkOS mirror" do
    user = user_fixture()
    scope = user_scope_fixture(user)

    assert {:ok, %Organization{} = organization} =
             Accounts.create_shared_organization(scope, %{name: "Acme Operations"})

    assert organization.personal == false
    assert organization.provisioning_state == :provisioning
    assert organization.workos_organization_id == nil
    refute Enum.any?(Accounts.list_user_organizations(user), &(&1.id == organization.id))

    membership =
      Repo.get_by!(OrganizationMembership,
        org_id: organization.id,
        user_id: user.id
      )

    assert membership.source == :workos
    assert membership.status == :inactive
    assert membership.role == :owner

    job = Repo.one!(Oban.Job)

    assert job.args == %{
             "organization_id" => organization.id,
             "owner_user_id" => user.id
           }

    assert job.worker == "Hermitscale.Accounts.OrganizationProvisioningWorker"
  end

  test "provisions organization and owner membership idempotently by external ID" do
    user = user_fixture()
    scope = user_scope_fixture(user)
    {:ok, organization} = Accounts.create_shared_organization(scope, %{name: "Acme Operations"})
    remote_timestamp = "2026-07-26T18:00:00.000000Z"

    Client.put_response(
      :create_organization,
      fn name, external_id ->
        {:ok,
         %{
           "id" => "org_workos_123",
           "external_id" => external_id,
           "name" => name,
           "created_at" => remote_timestamp,
           "updated_at" => remote_timestamp
         }}
      end
    )

    Client.put_response(
      :create_organization_membership,
      fn organization_id, user_id, role_slug ->
        {:ok,
         %{
           "id" => "membership_workos_123",
           "organization_id" => organization_id,
           "user_id" => user_id,
           "role" => %{"slug" => role_slug},
           "status" => "active",
           "created_at" => remote_timestamp,
           "updated_at" => remote_timestamp
         }}
      end
    )

    job = %Oban.Job{
      args: %{
        "organization_id" => organization.id,
        "owner_user_id" => user.id
      },
      attempt: 1,
      max_attempts: 12
    }

    assert :ok = OrganizationProvisioningWorker.perform(job)

    provisioned = Repo.reload!(organization)
    assert provisioned.provisioning_state == :ready
    assert provisioned.workos_organization_id == "org_workos_123"

    membership =
      Repo.get_by!(OrganizationMembership,
        org_id: organization.id,
        user_id: user.id
      )

    assert membership.status == :active
    assert membership.workos_membership_id == "membership_workos_123"

    remote_organization = %{
      "id" => "org_workos_123",
      "external_id" => organization.id,
      "name" => organization.name,
      "created_at" => remote_timestamp,
      "updated_at" => remote_timestamp
    }

    Client.put_response(:get_organization_by_external_id, {:ok, remote_organization})
    assert :ok = OrganizationProvisioningWorker.perform(job)

    create_calls =
      Client.calls()
      |> Enum.filter(fn {operation, _args} ->
        operation in [:create_organization, :create_organization_membership]
      end)

    assert length(create_calls) == 2
  end

  test "marks a shared organization unavailable after the final failed attempt" do
    user = user_fixture()
    scope = user_scope_fixture(user)
    {:ok, organization} = Accounts.create_shared_organization(scope, %{name: "Acme Operations"})
    Client.put_response(:get_organization_by_external_id, {:error, :unavailable})

    job = %Oban.Job{
      args: %{
        "organization_id" => organization.id,
        "owner_user_id" => user.id
      },
      attempt: 12,
      max_attempts: 12
    }

    assert {:error, {:organization_lookup_failed, :unavailable}} =
             OrganizationProvisioningWorker.perform(job)

    assert Repo.reload!(organization).provisioning_state == :unavailable
  end
end
