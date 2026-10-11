defmodule Hermitscale.WorkOS.StateReconcilerTest do
  use Hermitscale.DataCase, async: false

  alias Hermitscale.Integrations.{ConnectedAccount, ConnectedAccounts}
  alias Hermitscale.Repo

  alias Hermitscale.WorkOS.{
    AuthSession,
    EventCursor,
    StateReconciler,
    StateReconciliation
  }

  alias Hermitscale.WorkOSTest.Client

  import Hermitscale.AccountsFixtures

  setup do
    start_supervised!({Client, %{}})

    previous_reconciler = Application.get_env(:hermitscale, StateReconciler, [])
    previous_connections = Application.get_env(:hermitscale, ConnectedAccounts, [])

    Application.put_env(
      :hermitscale,
      StateReconciler,
      Keyword.put(previous_reconciler, :client, Client)
    )

    Application.put_env(
      :hermitscale,
      ConnectedAccounts,
      Keyword.put(previous_connections, :client, Client)
    )

    on_exit(fn ->
      Application.put_env(:hermitscale, StateReconciler, previous_reconciler)
      Application.put_env(:hermitscale, ConnectedAccounts, previous_connections)
    end)
  end

  test "records a complete generation, repairs missing sessions/connections, and resets events" do
    user = user_fixture()
    scope = user_scope_fixture(user)
    local_session = workos_session_fixture(user)
    account = connected_account_fixture(user, scope.organization)

    Client.put_response(:list_users, {:ok, page([remote_user(user)])})

    assert {:ok, %StateReconciliation{status: :completed} = reconciliation} =
             StateReconciler.reconcile()

    assert reconciliation.completed_at
    assert reconciliation.object_counts["users"] == 1
    assert reconciliation.object_counts["missing_sessions"] == 1
    assert reconciliation.object_counts["missing_connected_accounts"] == 1

    assert Repo.get!(AuthSession, local_session.session.id).revoked_at
    assert Repo.get!(ConnectedAccount, account.id).state == :disconnected

    cursor = Repo.get!(EventCursor, "primary")
    assert cursor.after_cursor == nil
    assert cursor.range_start
    assert DateTime.before?(cursor.range_start, reconciliation.started_at)
  end

  test "does not run absence detection or reset the cursor after an incomplete scan" do
    user = user_fixture()
    scope = user_scope_fixture(user)
    account = connected_account_fixture(user, scope.organization)

    Client.put_response(:list_users, {:ok, page([remote_user(user)])})
    Client.put_response(:list_organizations, {:error, :unavailable})

    assert {:error, :unavailable} = StateReconciler.reconcile()

    assert %StateReconciliation{status: :failed, error: error} =
             Repo.one!(StateReconciliation)

    assert error =~ "unavailable"
    assert Repo.get!(ConnectedAccount, account.id).state == :connected
    assert Repo.get(EventCursor, "primary") == nil
  end

  defp remote_user(user) do
    %{
      "id" => user.workos_user_id,
      "email" => user.email,
      "email_verified" => true,
      "first_name" => "Remote",
      "last_name" => "Projection",
      "created_at" => "2026-07-26T18:00:00.000000Z",
      "updated_at" => "2026-07-26T18:00:00.000000Z"
    }
  end

  defp page(data), do: %{"data" => data, "list_metadata" => %{"after" => nil}}
end
