defmodule Hermitscale.Workflows.CodingWorkflowTest do
  use Hermitscale.DataCase, async: false

  import Hermitscale.AgentsFixtures
  import Hermitscale.ProductFixtures
  import Hermitscale.WorkflowCodingFixtures
  import Hermitscale.WorkflowsFixtures, only: [graph_attrs: 1]

  alias Hermitscale.{Agents, AgentsRuntimeFake, Workflows}
  alias Hermitscale.Workflows.{Compiler, Engine, PostgresStore, Replay, Run}
  alias Runic.Workflow

  @runner Hermitscale.WorkflowRunner

  setup do
    %{current_scope: scope} = authenticated_product_fixture()
    configure_product_fixture(Hermitscale.Agents.Runtime, adapter: AgentsRuntimeFake)
    configure_product_fixture(:workspace_management_adapter, AgentsRuntimeFake)
    session = agent_session_fixture(scope)
    :ok = Agents.subscribe(scope, session.id)
    %{scope: scope, session: session}
  end

  test "native admission persists planned input and a coding node produces nothing before its turn completes",
       %{scope: scope, session: session} do
    start_supervised!({AgentsRuntimeFake, outcomes: [running(), success()]})

    {:ok, graph} =
      Workflows.create_graph(scope, graph_attrs(definition: coding_graph(session.id)))

    assert {:ok, run} = Workflows.start_run(scope, graph, %{"request" => "update"})
    assert run.status == :running
    assert run.output == nil
    watch_run(scope, run)
    assert Engine.productions(restore(run), "coding") == []
    assert Workflow.is_runnable?(restore(run))

    turn = admitted_turn(scope, session)
    assert {:ok, %{status: :running}} = Agents.reconcile_turn(scope, turn.id)
    assert Workflows.get_run!(scope, run.id).output == nil
    assert Engine.productions(restore(run), "coding") == []

    assert {:ok, %{status: :succeeded}} = Agents.reconcile_turn(scope, turn.id)
    assert %Run{status: :complete} = complete = await_run(scope, run, :run_complete)
    assert [result] = complete.output["value"]["coding"]
    assert result["turn_id"] == turn.id
    assert result["session_id"] == session.id
    assert result["outcome"] == "succeeded"
    assert Engine.productions(restore(complete), "coding") == [result]

    replayed = complete |> restore() |> Workflow.react_until_satisfied()
    assert Engine.productions(replayed, "coding") == [result]
    assert [same_turn] = Agents.list_turns(scope, session.id)
    assert same_turn.id == turn.id
    assert length(AgentsRuntimeFake.steps()) == 2
  end

  test "resume reuses the committed agent turn when its Runic result was not yet accepted",
       %{scope: scope, session: session} do
    start_supervised!({AgentsRuntimeFake, outcomes: [success()]})

    {:ok, graph} =
      Workflows.create_graph(scope, graph_attrs(definition: coding_graph(session.id)))

    {:ok, run} = Workflows.start_run(scope, graph, nil)
    watch_run(scope, run)
    turn = admitted_turn(scope, session)

    native_worker = Runic.Runner.lookup(@runner, run.id)
    state = :sys.get_state(native_worker)
    [node_task] = Map.values(state.executor_state.tasks)
    ref = Process.monitor(node_task)
    :ok = :sys.suspend(native_worker)

    assert {:ok, %{status: :succeeded}} = Agents.reconcile_turn(scope, turn.id)
    assert_receive {:DOWN, ^ref, :process, ^node_task, :normal}, 5_000
    assert :ok = Runic.Runner.cancel(@runner, run.id)
    assert Engine.productions(restore(run), "coding") == []

    changed =
      put_in(graph.definition, ["nodes", Access.at(0), "params", "instructions"], "A later task")

    assert {:ok, _graph} = Workflows.update_graph(scope, graph, %{definition: changed})
    assert {:ok, %Run{}} = Workflows.resume_run(scope, run)
    assert %Run{status: :complete} = complete = await_run(scope, run, :run_complete)
    assert complete.definition == run.definition
    assert [same_turn] = Agents.list_turns(scope, session.id)
    assert same_turn.id == turn.id
    assert same_turn.instructions == "Update the source"
    assert length(AgentsRuntimeFake.steps()) == 1
    assert [%{"turn_id" => id}] = Engine.productions(restore(complete), "coding")
    assert id == turn.id
  end

  test "equal mapped inputs retain separate keyed turns and accepted fact occurrences",
       %{scope: scope, session: session} do
    start_supervised!({AgentsRuntimeFake, outcomes: [success(), success()]})

    {:ok, graph} =
      Workflows.create_graph(scope, graph_attrs(definition: mapped_coding_graph(session.id)))

    {:ok, run} = Workflows.start_run(scope, graph, [1, 1])
    watch_run(scope, run)

    for _item <- 1..2,
        do: assert_receive({:agent_session_updated, id} when id == session.id, 5_000)

    turns = Agents.list_turns(scope, session.id) |> Enum.sort_by(& &1.admission_sequence)
    assert length(turns) == 2
    assert length(Enum.uniq_by(turns, & &1.operation_key)) == 2
    assert Enum.all?(turns, &(&1.instructions == "Update the source"))

    for turn <- turns,
        do: assert({:ok, %{status: :succeeded}} = Agents.reconcile_turn(scope, turn.id))

    assert %Run{status: :complete} = complete = await_run(scope, run, :run_complete)
    assert [results] = complete.output["value"]["results"]
    assert length(results) == 2
    assert MapSet.new(results, & &1["turn_id"]) == MapSet.new(turns, & &1.id)
    assert Enum.all?(results, &(&1["answer"] == "done"))
    replayed = restore(complete)
    facts = Workflow.productions(replayed, "coding")
    assert length(Enum.uniq_by(facts, & &1.hash)) == 2
    assert Enum.map(facts, &hd(&1.meta.hermitscale.frames).index) |> Enum.sort() == [0, 1]
    assert Engine.productions(replayed, "results") == [results]
    assert length(AgentsRuntimeFake.steps()) == 2
  end

  test "failed coding turns fail the run and never start downstream effects",
       %{scope: scope, session: session} do
    start_supervised!(
      {AgentsRuntimeFake,
       outcomes: [%{status: :failed, worker_state: %{}, error: %{"reason" => "provider_failed"}}]}
    )

    {:ok, graph} =
      Workflows.create_graph(scope, graph_attrs(definition: coding_effect_graph(session.id)))

    {:ok, run} = Workflows.start_run(scope, graph, nil)

    watch_run(scope, run)
    turn = admitted_turn(scope, session)
    assert {:ok, %{status: :failed}} = Agents.reconcile_turn(scope, turn.id)

    assert %Run{status: :failed, output: nil, error: error} =
             failed = await_run(scope, run, :run_failed)

    assert error != nil
    assert Engine.productions(restore(failed), "effect") == []
    assert [failed_turn] = Agents.list_turns(scope, session.id)
    assert failed_turn.id == turn.id
  end

  test "a cancelled stored workflow does not start native coding",
       %{scope: scope, session: session} do
    {:ok, graph} =
      Workflows.create_graph(scope, graph_attrs(definition: coding_graph(session.id)))

    assert {:ok, cancelled} =
             Workflows.create_run(scope, graph, %{
               status: :cancelled,
               completed_at: DateTime.utc_now(:second)
             })

    assert {:ok, %Run{status: :cancelled}} = Workflows.resume_run(scope, cancelled)
    assert Agents.list_turns(scope, session.id) == []
  end

  defp watch_run(scope, run) do
    :ok = Workflows.subscribe_run(scope, run.id)
    on_exit(fn -> Runic.Runner.cancel(@runner, run.id) end)
  end

  defp await_run(scope, run, event) do
    id = run.id
    assert_receive {^event, ^id}, 5_000
    Workflows.get_run!(scope, id)
  end

  defp admitted_turn(scope, session) do
    assert_receive {:agent_session_updated, id} when id == session.id, 5_000
    assert [turn] = Agents.list_turns(scope, session.id)
    turn
  end

  defp restore(run) do
    {:ok, events} = PostgresStore.stream(run.id, %{repo: Repo})
    {:ok, workflow} = Replay.restore(events, Compiler.compile!(run.definition))
    workflow
  end

  defp running, do: %{status: :running, worker_state: %{}}

  defp success,
    do: %{
      status: :succeeded,
      worker_state: %{"termination_confirmed" => true},
      result: %{"answer" => "done"}
    }
end
