defmodule Hermitscale.Workflows.CollectionWorkflowsTest do
  use ExUnit.Case, async: true

  import Hermitscale.CollectionWorkflowsFixtures

  alias Hermitscale.Workflows.{Compiler, Engine, Replay}
  alias Runic.Identity
  alias Runic.Workflow
  alias Runic.Workflow.Fact

  describe "compiled collection workflows" do
    test "unequal graph branch depths join by occurrence and aggregate in source order" do
      workflow = run(branching_collection_graph(), [1, 2, 1])

      assert Engine.productions(workflow, "collected") == [[[10, 200], [20, 300], [10, 200]]]
      assert :ok = Engine.completion(workflow)

      joined = Workflow.productions(workflow, "join")
      assert length(joined) == 3
      assert length(Enum.uniq_by(joined, & &1.hash)) == 3
    end

    test "empty maps finish joins and produce an empty aggregate" do
      workflow = run(branching_collection_graph(), [])

      assert Engine.productions(workflow, "join") == []
      assert Engine.productions(workflow, "collected") == [[]]
      assert :ok = Engine.completion(workflow)
    end

    test "nested maps close one scope at a time, retaining duplicates and empty inner lists" do
      for input <- [[[1, 1], [], [2]], [[], []], [], [[nil], [3, 3]]] do
        workflow = run(nested_collection_graph(), input)

        assert Engine.productions(workflow, "collected") == [input]
        assert :ok = Engine.completion(workflow)
      end
    end

    test "upstream history is occurrence-specific before collecting and ordered afterward" do
      workflow = run(history_collection_graph(), [1, 2, 1])

      assert [history] = Engine.productions(workflow, "history")

      assert history["items"] == [
               %{"left" => 10, "right" => 200, "item" => 1, "index" => 0},
               %{"left" => 20, "right" => 300, "item" => 2, "index" => 1},
               %{"left" => 10, "right" => 200, "item" => 1, "index" => 2}
             ]

      assert history["count"] == 3
      assert Enum.map(history["left"], & &1["json"]) == [10, 20, 10]
      assert length(Enum.uniq_by(history["left"], & &1["occurrence"])) == 3
    end

    test "collection payload join modes keep unequal branch lengths explicit" do
      cases = [
        {"zip_nil", [[1, "a"], [2, nil], [3, nil]]},
        {"zip_shortest", [[1, "a"]]},
        {"zip_cycle", [[1, "a"], [2, "a"], [3, "a"]]},
        {"cartesian", [[1, "a"], [2, "a"], [3, "a"]]},
        {"flatten", [1, 2, 3, "a"]}
      ]

      for {mode, expected} <- cases do
        workflow = run(payload_join_graph(mode, [1, 2, 3], ["a"]), :start)
        assert Engine.productions(workflow, "join") == [expected]
      end
    end

    test "empty collection payloads follow the configured join mode" do
      cases = [
        {"zip_nil", [[1, nil], [2, nil]]},
        {"zip_shortest", []},
        {"zip_cycle", [[1, nil], [2, nil]]},
        {"cartesian", []},
        {"flatten", [1, 2]}
      ]

      for {mode, expected} <- cases do
        workflow = run(payload_join_graph(mode, [1, 2], []), :start)
        assert Engine.productions(workflow, "join") == [expected]
      end
    end

    test "nil values are successful branch results rather than missing outcomes" do
      workflow = run(payload_join_graph("append", 3, nil), :start)
      assert Engine.productions(workflow, "join") == [[3, nil]]
    end

    test "collection zip modes pad an explicitly skipped branch as an empty collection" do
      for mode <- ["zip_nil", "zip_cycle"] do
        workflow = run(skipped_payload_join_graph(mode), :start)
        assert Engine.productions(workflow, "join") == [[[1, nil], [2, nil]]]
        assert :ok = Engine.completion(workflow)
      end
    end

    test "a successful nil scalar fails clearly when a collection join requires a list" do
      workflow =
        payload_join_graph("zip_nil", [1, 2], nil)
        |> Compiler.compile!()
        |> Workflow.plan_eagerly(:start)

      assert %{status: :failed, error: %ArgumentError{message: message}} =
               execute_until_failure(workflow)

      assert message =~ "collection join requires list inputs"
    end

    test "skipped branches retain their item and slot with nil or omit behavior" do
      input = [%{"n" => 1, "skip" => false}, %{"n" => 2, "skip" => true}]

      nil_workflow = run(skipped_collection_graph("nil"), input)
      assert Engine.productions(nil_workflow, "collected") == [[[1, 10], [2, nil]]]
      assert :ok = Engine.completion(nil_workflow)

      omit_workflow = run(skipped_collection_graph("omit"), input)
      assert Engine.productions(omit_workflow, "collected") == [[[1, 10], [2]]]
      assert :ok = Engine.completion(omit_workflow)
    end

    test "a strict join reports the missing branch and a halting failure reports its reason" do
      workflow =
        skipped_collection_graph("fail")
        |> Compiler.compile!()
        |> Workflow.plan_eagerly([%{"n" => 2, "skip" => true}])

      assert %{status: :failed, error: {:missing_join_inputs, "join", ["right"]}} =
               execute_until_failure(workflow)

      workflow =
        skipped_collection_graph("nil", %{"fail" => true})
        |> Compiler.compile!()
        |> Workflow.plan_eagerly([%{"n" => 2}])

      assert %{status: :failed, error: :fixture_failure} = execute_until_failure(workflow)
    end

    test "policy skips become durable missing outcomes without losing sibling occurrences" do
      workflow =
        run(
          skipped_collection_graph("nil", %{"fail" => true}, %{
            "on_failure" => "skip",
            "max_retries" => 0
          }),
          [%{"n" => 1}, %{"n" => 2}]
        )

      assert Engine.productions(workflow, "collected") == [[[1, nil], [2, nil]]]
      assert :ok = Engine.completion(workflow)
    end

    test "accepted per-item effects are not repeated after partial-event replay" do
      base = effect_collection_graph() |> Compiler.compile!() |> Workflow.enable_event_emission()
      runtime = Map.put(Workflow.get_run_context(base), "effects", %{observer: self()})

      partial =
        base
        |> Workflow.put_run_context(runtime)
        |> Workflow.plan_eagerly([5, 5, 8])
        |> execute_until_productions("effects", 3)

      assert_receive {:collection_effect, 5}
      assert_receive {:collection_effect, 5}
      assert_receive {:collection_effect, 8}
      assert Engine.productions(partial, "collected") == []

      events = [Replay.definition_event(base) | Enum.reverse(partial.uncommitted_events)]
      assert {:ok, replayed} = Replay.restore(events, base)

      restored =
        replayed
        |> Workflow.put_run_context(runtime)
        |> Workflow.react_until_satisfied()

      assert Engine.productions(restored, "collected") == [[5, 5, 8]]
      refute_receive {:collection_effect, _}
    end

    test "parallel source batches never pair equal payloads from different input occurrences" do
      first = Fact.new(value: [1, 2, 1], id: Identity.derive(:fact_occurrence, %{source: :first}))

      second =
        Fact.new(value: [1, 2, 1], id: Identity.derive(:fact_occurrence, %{source: :second}))

      workflow =
        branching_collection_graph()
        |> Compiler.compile!()
        |> Workflow.plan_eagerly(first)
        |> Workflow.plan_eagerly(second)
        |> execute_reversed_parallel()

      assert Engine.productions(workflow, "collected") == [
               [[10, 200], [20, 300], [10, 200]],
               [[10, 200], [20, 300], [10, 200]]
             ]

      facts = Workflow.productions(workflow, "collected")

      assert MapSet.new(facts, & &1.meta.hermitscale.root) ==
               MapSet.new([first.hash, second.hash])

      for fact <- Workflow.productions(workflow, "join") do
        state = fact.meta.hermitscale
        left = state.history["left"]
        right = state.history["right_next"]
        assert left["root"] == right["root"]
        assert left["ancestry"] == right["ancestry"]
      end

      assert :ok = Engine.completion(workflow)
    end
  end

  defp run(graph, input) do
    graph
    |> Compiler.compile!()
    |> Workflow.react_until_satisfied(input, async: true, max_concurrency: 4)
  end

  defp execute_until_failure(workflow, remaining \\ 30)
  defp execute_until_failure(_workflow, 0), do: flunk("workflow did not fail within 30 reactions")

  defp execute_until_failure(workflow, remaining) do
    {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)
    completed = Workflow.execute_with_policies(runnables, workflow.scheduler_policies)

    case Enum.find(completed, &(&1.status == :failed)) do
      nil ->
        assert completed != [], "workflow finished without the expected failure"
        workflow = Enum.reduce(completed, workflow, &Workflow.apply_runnable(&2, &1))
        execute_until_failure(workflow, remaining - 1)

      failed ->
        failed
    end
  end

  defp execute_until_productions(workflow, name, count, remaining \\ 30)

  defp execute_until_productions(_workflow, _name, _count, 0),
    do: flunk("workflow did not produce the expected effect outputs")

  defp execute_until_productions(workflow, name, count, remaining) do
    case length(Engine.productions(workflow, name)) do
      ^count -> workflow
      _count -> execute_until_productions(Workflow.react(workflow), name, count, remaining - 1)
    end
  end

  defp execute_reversed_parallel(workflow, remaining \\ 30)

  defp execute_reversed_parallel(_workflow, 0),
    do: flunk("workflow did not finish within 30 dispatches")

  defp execute_reversed_parallel(workflow, remaining) do
    {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

    case runnables do
      [] ->
        workflow

      runnables ->
        completed =
          runnables
          |> Task.async_stream(&Workflow.execute_runnable/1, ordered: false, timeout: :infinity)
          |> Enum.map(fn {:ok, runnable} -> runnable end)
          |> Enum.reverse()

        assert Enum.all?(completed, &(&1.status == :completed))
        workflow = Enum.reduce(completed, workflow, &Workflow.apply_runnable(&2, &1))
        execute_reversed_parallel(workflow, remaining - 1)
    end
  end
end
