defmodule Hermitscale.Agents.RuntimeE2ETest do
  use Hermitscale.DataCase, async: false
  import Hermitscale.ProductFixtures
  import Hermitscale.AgentsFixtures
  alias Hermitscale.{Agents, Artifacts, Workspaces, AgentsRuntimeFake, Usage}

  setup do
    authentication = authenticated_product_fixture()
    scope = authentication.current_scope
    configure_product_fixture(Hermitscale.Agents.Runtime, adapter: AgentsRuntimeFake)
    configure_product_fixture(:workspace_management_adapter, AgentsRuntimeFake)
    %{scope: scope, session: agent_session_fixture(scope)}
  end

  test "one retained writer runs, stores verified output and releases for a follow-up", %{
    scope: scope,
    session: session
  } do
    start_supervised!(
      {AgentsRuntimeFake,
       outcomes: [
         %{status: :running, worker_state: %{"provider_session_id" => "provider-thread"}},
         success(session),
         success(session)
       ]}
    )

    first = agent_turn_fixture(scope, session)
    second = agent_turn_fixture(scope, session)
    assert {:ok, running} = Agents.reconcile_turn(scope, first.id)
    assert running.status == :running
    assert {:error, :waiting_for_previous_turn} = Agents.reconcile_turn(scope, second.id)
    assert {:ok, completed} = Agents.reconcile_turn(scope, first.id)
    assert completed.status == :succeeded
    assert {:ok, artifact} = Artifacts.get(scope, completed.result["patch_artifact_id"])
    assert artifact.content == "verified diff"
    assert {:ok, %{status: :released}} = Workspaces.get_lease(scope, completed.lease_id)

    assert {:ok, %{provider_conversation_id: "provider-thread"}} =
             Agents.get_session(scope, session.id)

    assert {:ok, %{status: :succeeded}} = Agents.reconcile_turn(scope, second.id)
    [{start, original}, {poll, resumed}, {_followup, next}] = AgentsRuntimeFake.steps()
    assert start.worker_command_id == poll.worker_command_id
    assert original.id == resumed.id
    assert next.generation > original.generation
    _ = Agents.list_events(scope, session.id)
    _ = Agents.list_turns(scope, session.id)
    _ = Artifacts.get(scope, completed.result["patch_snapshot_artifact_id"])
    assert length(AgentsRuntimeFake.steps()) == 3
  end

  test "terminal commit is recoverable when the first writer release fails", %{
    scope: scope,
    session: session
  } do
    start_supervised!({AgentsRuntimeFake, outcomes: [success(session)], fail_release: true})
    turn = agent_turn_fixture(scope, session)
    assert {:error, :termination_unverified} = Agents.reconcile_turn(scope, turn.id)
    assert {:ok, %{status: :succeeded}} = Agents.get_turn(scope, turn.id)
    assert {:ok, %{status: :succeeded}} = Agents.reconcile_turn(scope, turn.id)

    assert %{
             compute: %{quantity: 2000, priced: false, unit: "milliseconds"},
             storage: %{quantity: 1024, priced: false, unit: "logical_file_bytes"}
           } = Usage.summary(scope, turn.id)

    assert {:ok, %{status: :released}} =
             Workspaces.get_lease(
               scope,
               hd(AgentsRuntimeFake.steps()) |> elem(1) |> Map.fetch!(:id)
             )

    assert length(AgentsRuntimeFake.steps()) == 1
  end

  test "invalid requested output fails without leaving a writer active", %{
    scope: scope,
    session: session
  } do
    start_supervised!({AgentsRuntimeFake, outcomes: [success(session)]})

    turn =
      agent_turn_fixture(scope, session, %{
        result_schema: %{"type" => "object", "required" => ["missing"]}
      })

    assert {:ok, %{status: :failed} = failed} = Agents.reconcile_turn(scope, turn.id)
    assert {:ok, %{status: :released}} = Workspaces.get_lease(scope, failed.lease_id)
    assert {:ok, _retained_patch} = Artifacts.get(scope, failed.result["patch_artifact_id"])
  end

  test "interrupted work keeps private file exports and measured usage for historical reads", %{
    scope: scope,
    session: session
  } do
    content = "partial fix\n"
    outcome = success(session)

    result =
      Map.put(outcome.result, "files", [
        %{
          "path" => "lib/fix.ex",
          "content" => Base.encode64(content),
          "digest" => Hermitscale.Workspaces.Evidence.digest(content)
        }
      ])

    start_supervised!(
      {AgentsRuntimeFake, outcomes: [%{outcome | status: :interrupted, result: result}]}
    )

    turn = agent_turn_fixture(scope, session)

    assert {:ok, interrupted} = Agents.reconcile_turn(scope, turn.id)
    assert interrupted.status == :interrupted
    [export] = interrupted.result["exports"]
    assert {:ok, %{content: ^content}} = Artifacts.get(scope, export["artifact_id"])

    assert {:ok, snapshot} =
             Artifacts.get(scope, interrupted.result["patch_snapshot_artifact_id"])

    assert {:ok, %{"exports" => [^export]}} = Jason.decode(snapshot.content)

    assert {:ok, %{usage_summary: %{compute: %{quantity: 2000}}}} =
             Agents.get_turn(scope, turn.id)

    assert {:ok, %{status: :released}} = Workspaces.get_lease(scope, interrupted.lease_id)
    assert length(AgentsRuntimeFake.steps()) == 1
  end

  test "malformed file evidence is rejected at the runtime boundary", %{
    scope: scope,
    session: session
  } do
    outcome = success(session)

    result =
      Map.put(outcome.result, "files", [%{"path" => "fix.ex", "content" => nil, "digest" => 42}])

    start_supervised!({AgentsRuntimeFake, outcomes: [%{outcome | result: result}]})
    turn = agent_turn_fixture(scope, session)
    assert {:error, :invalid_export} = Agents.reconcile_turn(scope, turn.id)
  end

  test "missing or null terminal output cannot bypass success validation", %{
    scope: scope,
    session: session
  } do
    outcome = success(session)

    start_supervised!(
      {AgentsRuntimeFake, outcomes: [Map.delete(outcome, :result), %{outcome | result: nil}]}
    )

    for _case <- 1..2 do
      turn = agent_turn_fixture(scope, session)

      assert {:ok, %{status: :failed, result: %{"outcome" => "invalid_result"}} = failed} =
               Agents.reconcile_turn(scope, turn.id)

      assert {:ok, %{status: :released}} = Workspaces.get_lease(scope, failed.lease_id)
    end
  end

  test "current-turn output evidence is required even with an empty requested schema", %{
    scope: scope,
    session: session
  } do
    outcome = success(session)
    absent = Map.merge(outcome.result, %{"result" => nil, "result_evidence_present" => false})

    invalid =
      Map.merge(outcome.result, %{
        "result" => nil,
        "result_evidence_present" => true,
        "result_valid_json" => false
      })

    start_supervised!(
      {AgentsRuntimeFake, outcomes: [%{outcome | result: absent}, %{outcome | result: invalid}]}
    )

    for _case <- 1..2 do
      turn = agent_turn_fixture(scope, session)
      assert {:ok, %{status: :failed} = failed} = Agents.reconcile_turn(scope, turn.id)
      assert failed.result["outcome"] == "invalid_result"
      assert {:ok, _retained_patch} = Artifacts.get(scope, failed.result["patch_artifact_id"])
      assert {:ok, %{status: :released}} = Workspaces.get_lease(scope, failed.lease_id)
    end
  end

  defp success(session),
    do: %{
      status: :succeeded,
      worker_state: %{
        "provider_session_id" => "provider-thread",
        "termination_confirmed" => true,
        "compute_milliseconds" => 2000
      },
      result: %{
        "base_sha" => session.base_sha,
        "head_sha" => session.base_sha,
        "diff" => "verified diff",
        "checks" => [%{"name" => "repository tests", "exit_code" => 0}],
        "manifest" => ["lib/fix.ex"],
        "files" => [],
        "storage_bytes" => 1024,
        "result" => %{}
      }
    }
end
