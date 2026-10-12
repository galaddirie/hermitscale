defmodule Hermitscale.Workflows.UpstreamCompatibilityTest do
  use ExUnit.Case, async: true

  import Hermitscale.WorkflowsFixtures

  alias Hermitscale.Workflows.{Compiler, Replay}
  alias Runic.Workflow

  test "equal mapped values retain collection cardinality through the application compiler" do
    graph = constant_map_reduce_graph()

    executed = graph |> Compiler.compile!() |> Workflow.react_until_satisfied([2, 2, 3])
    assert Workflow.raw_productions(executed, "summer") == [9]
  end

  test "replays a partially executed application map region against its compiled base" do
    base = map_reduce_graph() |> Compiler.compile!() |> Workflow.enable_event_emission()

    partial =
      base
      |> Workflow.react([%{"n" => 1}, %{"n" => 2}, %{"n" => 3}], [])
      |> Workflow.react()

    refute 60 in Workflow.raw_productions(partial, "summer")
    assert Workflow.is_runnable?(partial)

    events =
      partial
      |> Map.fetch!(:uncommitted_events)
      |> Enum.reverse()
      |> :erlang.term_to_binary()
      |> :erlang.binary_to_term([:safe])

    assert {:ok, replayed} = Replay.restore([Replay.definition_event(base) | events], base)
    restored = Workflow.react_until_satisfied(replayed)

    assert Workflow.raw_productions(restored, "summer") == [60]
  end

  test "iteration indexes, duplicate item occurrences and total count survive reduction and replay" do
    base = map_reduce_graph() |> Compiler.compile!() |> Workflow.enable_event_emission()

    executed =
      Workflow.react_until_satisfied(base, [%{"n" => 3}, %{"n" => 1}, %{"n" => 3}, %{"n" => 2}])

    expected = [{0, 30}, {1, 10}, {2, 30}, {3, 20}]

    assert mapper_rows(executed) == expected
    assert Enum.find(mapper_rows(executed), fn {index, _} -> index == 1 end) == {1, 10}
    assert iteration_count(executed) == 4
    assert Workflow.raw_productions(executed, "summer") == [90]

    events = Enum.reverse(executed.uncommitted_events)
    assert {:ok, replayed} = Replay.restore([Replay.definition_event(base) | events], base)
    assert mapper_rows(replayed) == expected
    assert iteration_count(replayed) == 4
    assert iteration_count(Workflow.react_until_satisfied(base, [])) == 0
  end

  defp mapper_rows(workflow) do
    facts = Map.new(Workflow.facts(workflow), &{&1.hash, &1})

    workflow
    |> Workflow.productions("mapper")
    |> Enum.map(fn output ->
      {_producer, item_id} = output.ancestry
      item = Map.fetch!(facts, item_id)
      {item.causal_ancestry.output_index, output.value.params.value}
    end)
    |> Enum.sort()
  end

  defp iteration_count(workflow) do
    fan_out = Workflow.get_component!(workflow, "mapper$fanout")

    items =
      workflow
      |> Workflow.facts()
      |> Enum.filter(fn fact ->
        match?({producer, _} when producer == fan_out.hash, fact.ancestry) and
          fact.meta.hermitscale.status == :ok
      end)

    assert length(Enum.uniq_by(items, & &1.hash)) == length(items)
    length(items)
  end
end
