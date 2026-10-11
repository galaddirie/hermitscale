defmodule Hermitscale.WorkOS.EventProcessorTest do
  use Hermitscale.DataCase, async: false

  alias Hermitscale.Accounts
  alias Hermitscale.Integrations.{ConnectedAccount, ConnectedAccounts}
  alias Hermitscale.Repo
  alias Hermitscale.WorkOS.{AuthSession, EventProcessor}

  import Hermitscale.AccountsFixtures

  test "a stale user update cannot resurrect or change a deletion-pending user" do
    created_at = ~U[2026-07-26 14:00:00.000000Z]
    deleted_at = ~U[2026-07-26 15:00:00Z]

    user =
      user_fixture(%{workos_user_id: "user_out_of_order"})

    user
    |> Accounts.User.workos_changeset(%{
      workos_user_id: user.workos_user_id,
      email: user.email,
      email_verified: true,
      workos_updated_at: created_at,
      confirmed_at: user.confirmed_at
    })
    |> Repo.update!()

    assert :ok =
             EventProcessor.apply(%{
               "event" => "user.deleted",
               "created_at" => DateTime.to_iso8601(deleted_at),
               "data" => %{"id" => user.workos_user_id}
             })

    stale_update = %{
      "id" => user.workos_user_id,
      "email" => "stale-update@example.com",
      "email_verified" => true,
      "updated_at" => DateTime.to_iso8601(created_at)
    }

    assert :ok =
             EventProcessor.apply(%{
               "event" => "user.updated",
               "created_at" => DateTime.to_iso8601(created_at),
               "data" => stale_update
             })

    persisted = Repo.get!(Accounts.User, user.id)
    assert persisted.email == user.email
    assert persisted.deletion_pending_at == deleted_at
  end

  test "membership deletion immediately revokes scoped sessions" do
    user = user_fixture()
    organization = shared_organization_fixture()

    membership =
      organization_membership_fixture(user, organization,
        role: :member,
        source: :workos,
        status: :active,
        workos_membership_id: "membership_123",
        workos_role_slug: "member",
        workos_updated_at: ~U[2026-07-26 14:00:00.000000Z]
      )

    local_session = workos_session_fixture(user, org_id: organization.id)

    assert :ok =
             EventProcessor.apply(%{
               "event" => "organization_membership.deleted",
               "created_at" => "2026-07-26T15:00:00.000000Z",
               "data" => %{
                 "id" => membership.workos_membership_id,
                 "user_id" => user.workos_user_id,
                 "organization_id" => organization.workos_organization_id,
                 "role" => %{"slug" => "member"},
                 "status" => "inactive",
                 "updated_at" => "2026-07-26T15:00:00.000000Z"
               }
             })

    assert Repo.reload!(membership).status == :deleted
    assert Repo.get!(AuthSession, local_session.session.id).revoked_at
  end

  test "unknown WorkOS role slugs fail closed" do
    user = user_fixture()
    organization = shared_organization_fixture()

    assert :ok =
             EventProcessor.apply(%{
               "event" => "organization_membership.created",
               "created_at" => "2026-07-26T15:00:00.000000Z",
               "data" => %{
                 "id" => "membership_unknown_role",
                 "user_id" => user.workos_user_id,
                 "organization_id" => organization.workos_organization_id,
                 "role" => %{"slug" => "super-admin"},
                 "status" => "active",
                 "updated_at" => "2026-07-26T15:00:00.000000Z"
               }
             })

    membership =
      Repo.get_by!(Accounts.OrganizationMembership,
        workos_membership_id: "membership_unknown_role"
      )

    assert membership.status == :inactive
    assert membership.role == :member
    assert Accounts.get_user_membership(user, organization.id) == nil
  end

  test "reauthorization and disconnect events make a connection unusable" do
    user = user_fixture()
    scope = user_scope_fixture(user)

    account =
      connected_account_fixture(user, scope.organization,
        workos_updated_at: ~U[2026-07-26 14:00:00.000000Z]
      )

    assert :ok =
             EventProcessor.apply(%{
               "event" => "pipes.connected_account.reauthorization_needed",
               "created_at" => "2026-07-26T16:00:00.000000Z",
               "data" => %{
                 "id" => account.workos_connected_account_id,
                 "user_id" => user.workos_user_id,
                 "data_provider_slug" => "google",
                 "state" => "needs_reauthorization",
                 "scopes" => account.granted_scopes,
                 "updated_at" => "2026-07-26T16:00:00.000000Z"
               }
             })

    assert Repo.reload!(account).state == :needs_reauthorization

    assert {:error, :needs_reauthorization} =
             ConnectedAccounts.credential_ref(
               scope.organization.id,
               account.provider_id,
               account.id,
               []
             )

    assert :ok =
             EventProcessor.apply(%{
               "event" => "pipes.connected_account.disconnected",
               "created_at" => "2026-07-26T17:00:00.000000Z",
               "data" => %{
                 "id" => account.workos_connected_account_id,
                 "user_id" => user.workos_user_id,
                 "provider_slug" => "google",
                 "scopes" => account.granted_scopes,
                 "updated_at" => "2026-07-26T17:00:00.000000Z"
               }
             })

    assert %ConnectedAccount{state: :disconnected, disconnected_at: disconnected_at} =
             Repo.reload!(account)

    assert disconnected_at == ~U[2026-07-26 17:00:00Z]
  end

  test "persists no mutation for unsupported event types" do
    assert {:ignored, :unsupported_event_type} =
             EventProcessor.apply(%{
               "event" => "future.resource.changed",
               "data" => %{"id" => "future_1"}
             })
  end

  defp shared_organization_fixture do
    organization_fixture(
      workos_organization_id: "org_#{System.unique_integer([:positive])}",
      provisioning_state: :ready,
      workos_updated_at: ~U[2026-07-26 13:00:00.000000Z]
    )
  end
end
