defmodule Hermitscale.Accounts.AccountDeletionWorkerTest do
  use Hermitscale.DataCase, async: false

  alias Hermitscale.Accounts
  alias Hermitscale.Accounts.AccountDeletionWorker
  alias Hermitscale.Integrations.{ConnectedAccount, ConnectedAccounts}
  alias Hermitscale.Repo
  alias Hermitscale.WorkOS.AuthSession
  alias Hermitscale.WorkOSTest.Client

  import Hermitscale.AccountsFixtures

  setup do
    start_supervised!({Client, %{}})

    previous_worker = Application.get_env(:hermitscale, AccountDeletionWorker, [])
    previous_connections = Application.get_env(:hermitscale, ConnectedAccounts, [])

    Application.put_env(
      :hermitscale,
      AccountDeletionWorker,
      Keyword.put(previous_worker, :client, Client)
    )

    Application.put_env(
      :hermitscale,
      ConnectedAccounts,
      Keyword.put(previous_connections, :client, Client)
    )

    on_exit(fn ->
      Application.put_env(:hermitscale, AccountDeletionWorker, previous_worker)
      Application.put_env(:hermitscale, ConnectedAccounts, previous_connections)
    end)
  end

  test "revokes sessions, disconnects Pipes, deletes WorkOS, and redacts local PII" do
    user = user_fixture(%{email: "delete-me@example.com"})
    scope = user_scope_fixture(user)
    local_session = workos_session_fixture(user)
    account = connected_account_fixture(user, scope.organization)
    assert {:ok, _pending} = Accounts.request_account_deletion(scope)

    job = %Oban.Job{args: %{"user_id" => user.id}}
    assert :ok = AccountDeletionWorker.perform(job)

    deleted_user = Repo.get!(Accounts.User, user.id)
    assert deleted_user.deleted_at
    assert deleted_user.deletion_pending_at
    assert deleted_user.email == "deleted+#{user.id}@invalid.local"
    assert deleted_user.first_name == nil
    assert deleted_user.last_name == nil
    assert Repo.get!(AuthSession, local_session.session.id).revoked_at

    assert %ConnectedAccount{state: :disconnected, deleted_at: deleted_at} =
             Repo.get!(ConnectedAccount, account.id)

    assert deleted_at

    operations = Enum.map(Client.calls(), &elem(&1, 0))
    assert :revoke_session in operations
    assert :delete_connected_account in operations
    assert :delete_user in operations

    previous_calls = Client.calls()
    assert :ok = AccountDeletionWorker.perform(job)
    assert Client.calls() == previous_calls
  end

  test "keeps the user pending and retryable if remote cleanup is unavailable" do
    user = user_fixture()
    scope = user_scope_fixture(user)
    connected_account_fixture(user, scope.organization)
    assert {:ok, _pending} = Accounts.request_account_deletion(scope)
    Client.put_response(:delete_connected_account, {:error, :unavailable})

    assert {:error, {:connected_account_cleanup_failed, :unavailable}} =
             AccountDeletionWorker.perform(%Oban.Job{args: %{"user_id" => user.id}})

    persisted = Repo.get!(Accounts.User, user.id)
    assert persisted.deletion_pending_at
    assert persisted.deleted_at == nil
  end
end
