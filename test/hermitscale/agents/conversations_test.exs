defmodule Hermitscale.Agents.ConversationsTest do
  use Hermitscale.DataCase, async: false
  use Oban.Testing, repo: Hermitscale.Repo
  import Hermitscale.AgentsFixtures
  alias Hermitscale.{Agents, Workspaces}
  alias Hermitscale.Agents.ReconcileWorker

  setup do
    scope = agent_scope_fixture()
    provider = Hermitscale.AuthTest.Provider
    original = Application.fetch_env!(:hermitscale, Hermitscale.Auth)
    Application.put_env(:hermitscale, Hermitscale.Auth, provider: provider)
    on_exit(fn -> Application.put_env(:hermitscale, Hermitscale.Auth, original) end)

    start_supervised!(
      {provider,
       %{
         user: scope.user,
         organizations: %{scope.organization.id => scope.organization},
         memberships: %{
           "agent-owner" => Map.merge(scope.membership, %{id: "agent-owner", status: "active"})
         }
       }}
    )

    %{scope: scope, session: agent_session_fixture(scope)}
  end

  test "admission persists input, one event and one dispatch job, without allocating compute", %{
    scope: scope,
    session: session
  } do
    turn = agent_turn_fixture(scope, session)
    assert turn.status == :queued
    assert_enqueued(worker: ReconcileWorker, args: %{turn_id: turn.id})
    assert [%{type: "turn.queued", sequence: 1}] = Agents.list_events(scope, session.id)

    assert {:ok, %{resource_state: :provision_pending, generation: 0}} =
             Workspaces.get_workspace(scope, session.workspace_id)
  end

  test "retries reuse immutable turn identity and reject changed input", %{
    scope: scope,
    session: session
  } do
    key = Ecto.UUID.generate()
    turn = agent_turn_fixture(scope, session, %{operation_key: key})

    assert {:ok, retry} =
             Agents.submit_turn(scope, session.id, %{
               instructions: turn.instructions,
               operation_key: key
             })

    assert retry.id == turn.id

    assert {:error, :operation_key_conflict} =
             Agents.submit_turn(scope, session.id, %{
               instructions: "Different instructions",
               operation_key: key
             })

    assert length(Agents.list_turns(scope, session.id)) == 1
    assert length(Agents.list_events(scope, session.id)) == 1
  end

  test "concurrent creation retries return one retained conversation", %{scope: scope} do
    key = Ecto.UUID.generate()
    task_supervisor = start_supervised!(Task.Supervisor)
    attrs = %{title: "Concurrent conversation", operation_key: key}
    parent = self()

    tasks =
      for _request <- 1..2 do
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          send(parent, {:creation_ready, self()})

          receive do
            :create ->
              Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                Agents.start_session(scope, attrs)
              end)
          end
        end)
      end

    for _request <- tasks do
      assert_receive {:creation_ready, pid}
      send(pid, :create)
    end

    [{:ok, first}, {:ok, retry}] = Enum.map(tasks, &Task.await(&1, 5000))

    try do
      assert first.id == retry.id
      assert first.workspace_id == retry.workspace_id
      assert {:ok, ^first} = Agents.start_session(scope, attrs)

      assert {:error, :session_key_conflict} =
               Agents.start_session(scope, %{attrs | title: "Changed request"})
    after
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        ids = Enum.uniq([first.id, retry.id])
        workspace_ids = Enum.uniq([first.workspace_id, retry.workspace_id])
        Repo.delete_all(from s in Hermitscale.Agents.Session, where: s.id in ^ids)
        Repo.delete_all(from w in Hermitscale.Workspaces.Workspace, where: w.id in ^workspace_ids)
      end)
    end
  end

  test "private sessions require both organization and initiating member", %{
    scope: scope,
    session: session
  } do
    outsider = agent_scope_fixture()
    assert {:error, :not_found} = Agents.get_session(outsider, session.id)

    colleague = %{
      scope
      | user: %{scope.user | id: "colleague"},
        membership: %{scope.membership | user_id: "colleague"}
    }

    assert {:error, :not_found} = Agents.get_session(colleague, session.id)
    assert [] == Agents.list_sessions(colleague)
    denied = %{scope | membership: %{scope.membership | permissions: []}}
    assert {:error, :forbidden} = Agents.submit_turn(denied, session.id, %{})
    assert {:error, :not_found} = Agents.get_session(scope, "not-a-uuid")
  end

  test "caller cannot replace ownership, workspace or operation state", %{
    scope: scope,
    session: session
  } do
    turn =
      agent_turn_fixture(scope, session, %{
        org_id: "evil",
        execution_actor_user_id: "evil",
        status: :succeeded,
        result: %{proof: "invented"}
      })

    assert turn.org_id == scope.organization.id
    assert turn.execution_actor_user_id == scope.user.id
    assert turn.status == :queued
    assert is_nil(turn.result)
  end

  test "invalid budget/input rolls back admission and dispatch together", %{
    scope: scope,
    session: session
  } do
    assert {:error, changeset} =
             Agents.submit_turn(scope, session.id, %{
               instructions: "",
               operation_key: "valid-key",
               budget_cents: -1
             })

    assert "can't be blank" in errors_on(changeset).instructions
    assert [] == Agents.list_turns(scope, session.id)
    assert [] == Agents.list_events(scope, session.id)
    refute_enqueued(worker: ReconcileWorker)
  end

  test "follow ups serialize by admission order even with identical input and timestamps", %{
    scope: scope,
    session: session
  } do
    first = agent_turn_fixture(scope, session)
    second = agent_turn_fixture(scope, session)
    assert first.id != second.id
    assert first.admission_sequence < second.admission_sequence
    assert {:error, :waiting_for_previous_turn} = Agents.reconcile_turn(scope, second.id)

    assert {:ok, %{status: :interrupted, error: %{"reason" => "sprites_token_missing"}}} =
             Agents.reconcile_turn(scope, first.id)

    assert {:ok, %{status: :interrupted}} = Agents.reconcile_turn(scope, second.id)
    assert length(Agents.list_events(scope, session.id)) == 4
    assert {:ok, _} = Agents.reconcile_turn(scope, first.id)
    assert length(Agents.list_events(scope, session.id)) == 4
  end

  test "queued cancellation is durable and idempotent, and keeps files", %{
    scope: scope,
    session: session
  } do
    turn = agent_turn_fixture(scope, session)
    assert {:ok, cancelled} = Agents.cancel_turn(scope, turn.id)
    assert cancelled.status == :cancelled
    assert cancelled.cancellation_requested_at
    assert {:ok, ^cancelled} = Agents.cancel_turn(scope, turn.id)

    assert {:ok, %{resource_state: :provision_pending}} =
             Workspaces.get_workspace(scope, session.workspace_id)

    assert length(Agents.list_events(scope, session.id)) == 2
  end

  test "archive and close preserve pending turns and workspace", %{scope: scope, session: session} do
    turn = agent_turn_fixture(scope, session)
    assert {:ok, %{status: :archived}} = Agents.update_session(scope, session.id, :archived)

    assert {:error, :session_not_open} =
             Agents.submit_turn(scope, session.id, %{
               instructions: "More",
               operation_key: Ecto.UUID.generate()
             })

    assert {:ok, %{status: :open}} = Agents.update_session(scope, session.id, :open)
    assert {:ok, %{status: :closed}} = Agents.update_session(scope, session.id, :closed)
    assert {:error, :session_closed} = Agents.update_session(scope, session.id, :open)
    assert {:ok, %{status: :queued}} = Agents.get_turn(scope, turn.id)
    assert {:ok, _} = Workspaces.get_workspace(scope, session.workspace_id)
  end

  test "history cursor and reverse pagination use stored monotonic sequence", %{
    scope: scope,
    session: session
  } do
    first = agent_turn_fixture(scope, session)
    _second = agent_turn_fixture(scope, session)
    {:ok, _} = Agents.cancel_turn(scope, first.id)

    assert [%{sequence: 2}, %{sequence: 3}] =
             Agents.list_events(scope, session.id, after_sequence: 1)

    assert [%{sequence: 2}] = Agents.list_events(scope, session.id, before_sequence: 3, limit: 1)
    assert [%{id: id}] = Agents.list_turns(scope, session.id, before_admission_sequence: 2)
    assert id == first.id
  end

  test "broadcast happens only for a committed transition", %{scope: scope, session: session} do
    assert :ok = Agents.subscribe(scope, session.id)
    _turn = agent_turn_fixture(scope, session)
    assert_receive {:agent_session_updated, id}
    assert id == session.id
    assert {:error, _} = Agents.submit_turn(scope, session.id, %{})
    refute_receive {:agent_session_updated, _}
  end

  test "remote stop remains intent until termination is independently verified", %{
    scope: scope,
    session: session
  } do
    turn = agent_turn_fixture(scope, session)

    turn
    |> Ecto.Changeset.change(status: :running, dispatched_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert {:ok, %{status: :running, cancellation_requested_at: requested, completed_at: nil}} =
             Agents.cancel_turn(scope, turn.id)

    assert requested

    assert [%{type: "turn.queued"}, %{type: "turn.cancellation_requested"}] =
             Agents.list_events(scope, session.id)
  end

  test "worker evidence is committed and deduplicated without granting a successful outcome", %{
    scope: scope,
    session: session
  } do
    turn = agent_turn_fixture(scope, session)

    {:ok, lease} =
      Workspaces.admit_lease(
        scope,
        session.workspace_id,
        turn.operation_key,
        DateTime.add(DateTime.utc_now(:second), 300)
      )

    event = %{
      "version" => 1,
      "workspace_id" => session.workspace_id,
      "operation_id" => turn.id,
      "epoch" => "0123456789abcdef0123456789abcdef",
      "cursor" => 1,
      "type" => "provider",
      "payload" => %{"summary" => "proposed fix", "access_token" => "secret"}
    }

    assert {:ok, [record]} = Agents.record_worker_events(scope, turn.id, lease.id, [event])
    refute record.payload["access_token"] == "secret"
    assert {:ok, [duplicate]} = Agents.record_worker_events(scope, turn.id, lease.id, [event])
    assert duplicate.id == record.id

    assert {:error, :event_source_conflict} =
             Agents.record_worker_events(scope, turn.id, lease.id, [
               put_in(event, ["payload", "summary"], "changed")
             ])

    assert {:error, :event_identity_mismatch} =
             Agents.record_worker_events(scope, turn.id, lease.id, [
               Map.put(event, "operation_id", Ecto.UUID.generate())
             ])

    assert {:ok, %{status: :queued, result: nil}} = Agents.get_turn(scope, turn.id)
    assert length(Agents.list_events(scope, session.id)) == 2
  end
end
