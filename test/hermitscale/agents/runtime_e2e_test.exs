defmodule Hermitscale.Agents.RuntimeE2ETest do
  use Hermitscale.DataCase, async: false
  import Hermitscale.ProductFixtures
  import Hermitscale.AgentsFixtures
  alias Hermitscale.{Agents, Workspaces, AgentsRuntimeFake}

  setup do
    %{current_scope: scope} = authenticated_product_fixture()
    configure_product_fixture(Hermitscale.Agents.Runtime, adapter: AgentsRuntimeFake)
    configure_product_fixture(:workspace_management_adapter, AgentsRuntimeFake)
    %{scope: scope, session: agent_session_fixture(scope)}
  end

  test "retained turns serialize and preserve provider history without scanning artifacts", %{
    scope: scope,
    session: session
  } do
    start_supervised!({AgentsRuntimeFake, outcomes: [running(), success(), success()]})
    first = agent_turn_fixture(scope, session)
    second = agent_turn_fixture(scope, session)
    assert {:ok, %{status: :running}} = Agents.reconcile_turn(scope, first.id)
    assert {:error, :waiting_for_previous_turn} = Agents.reconcile_turn(scope, second.id)
    assert {:ok, %{status: :succeeded} = completed} = Agents.reconcile_turn(scope, first.id)
    assert completed.result["session_id"] == session.id
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
    assert length(AgentsRuntimeFake.steps()) == 3
  end

  test "terminal persistence survives a failed writer release without another turn", %{
    scope: scope,
    session: session
  } do
    start_supervised!({AgentsRuntimeFake, outcomes: [success()], fail_release: true})
    turn = agent_turn_fixture(scope, session)
    assert {:error, :termination_unverified} = Agents.reconcile_turn(scope, turn.id)
    assert {:ok, %{status: :succeeded}} = Agents.get_turn(scope, turn.id)
    assert {:ok, %{status: :succeeded}} = Agents.reconcile_turn(scope, turn.id)
    [{_turn, lease}] = AgentsRuntimeFake.steps()
    assert {:ok, %{status: :released}} = Workspaces.get_lease(scope, lease.id)
  end

  test "ordinary chat can complete without JSON or diagnostic results", %{
    scope: scope,
    session: session
  } do
    outcome = success()

    start_supervised!(
      {AgentsRuntimeFake, outcomes: [Map.delete(outcome, :result), %{outcome | result: nil}]}
    )

    for _case <- 1..2 do
      turn = agent_turn_fixture(scope, session)
      assert {:ok, %{status: :succeeded} = completed} = Agents.reconcile_turn(scope, turn.id)
      assert {:ok, %{status: :released}} = Workspaces.get_lease(scope, completed.lease_id)
    end
  end

  test "requested structured output validates only the current turn", %{
    scope: scope,
    session: session
  } do
    outcome = %{success() | result: %{"result" => %{"answer" => "done"}}}

    start_supervised!(
      {AgentsRuntimeFake,
       outcomes: [outcome, %{outcome | result: %{"result_evidence_present" => false}}]}
    )

    schema = %{"type" => "object", "required" => ["answer"]}
    first = agent_turn_fixture(scope, session, %{result_schema: schema})

    assert {:ok, %{status: :succeeded, result: %{"result" => %{"answer" => "done"}}}} =
             Agents.reconcile_turn(scope, first.id)

    second = agent_turn_fixture(scope, session, %{result_schema: schema})
    assert {:ok, %{status: :failed} = failed} = Agents.reconcile_turn(scope, second.id)
    assert failed.result["outcome"] == "invalid_result"
    assert {:ok, %{status: :released}} = Workspaces.get_lease(scope, failed.lease_id)
  end

  test "caller-selected checks remain history rather than a universal chat success requirement",
       %{scope: scope, session: session} do
    outcome = %{success() | result: %{"checks" => [%{"command" => "false", "exit_code" => 1}]}}
    start_supervised!({AgentsRuntimeFake, outcomes: [outcome]})
    turn = agent_turn_fixture(scope, session, %{verification_commands: ["false"]})
    assert {:ok, completed} = Agents.reconcile_turn(scope, turn.id)
    assert completed.status == :succeeded
    assert [%{"exit_code" => 1}] = completed.result["checks"]
  end

  test "verification admission rejects null input and bounds explicit checks", %{
    scope: scope,
    session: session
  } do
    for commands <- [nil, List.duplicate("true", 11), [String.duplicate("x", 4097)]] do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Agents.submit_turn(scope, session.id, %{
                 instructions: "Explain the code",
                 operation_key: Ecto.UUID.generate(),
                 verification_commands: commands
               })

      assert Keyword.has_key?(changeset.errors, :verification_commands)
    end
  end

  defp running,
    do: %{status: :running, worker_state: %{"provider_session_id" => "provider-thread"}}

  defp success,
    do: %{
      status: :succeeded,
      worker_state: %{"provider_session_id" => "provider-thread", "termination_confirmed" => true},
      result: %{}
    }
end
