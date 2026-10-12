defmodule Hermitscale.Workflows.CollectionEngineTest do
  use ExUnit.Case, async: true

  import Hermitscale.CollectionEngineFixtures

  alias Hermitscale.Workflows.Engine
  alias Hermitscale.Workflows.Engine.{Collect, FanOut, Join, Metadata}
  alias Runic.Workflow
  alias Runic.Workflow.Invokable

  describe "collection occurrences" do
    test "equal values have separate indexed occurrences and durable lineage" do
      base = collection_workflow_fixture()

      executed = Workflow.react_until_satisfied(base, [4, 4, 7])
      facts = Workflow.productions(executed, "items$fan_out")

      assert Enum.sort(Enum.map(facts, & &1.value)) == [4, 4, 7]
      assert length(Enum.uniq_by(facts, & &1.hash)) == 3

      indexed =
        facts
        |> Enum.map(fn fact ->
          [frame] = fact.meta.hermitscale.frames
          assert frame.item == fact.hash
          assert frame.map == "items"
          assert frame.size == 3
          {frame.index, frame.value, fact.value}
        end)
        |> Enum.sort()

      assert indexed == [{0, 4, 4}, {1, 4, 4}, {2, 7, 7}]

      replayed = Workflow.apply_events(base, Enum.reverse(executed.uncommitted_events))

      assert Enum.sort_by(Workflow.productions(replayed, "items$fan_out"), & &1.hash) ==
               Enum.sort_by(facts, & &1.hash)
    end

    test "unequal branch depths join each occurrence in declared parent order" do
      executed = Workflow.react_until_satisfied(branch_workflow_fixture(), [1, 2, 1], async: true)

      assert Workflow.raw_productions(executed, "collected") == [[[2, 10], [3, 20], [2, 10]]]

      [collected] = Workflow.productions(executed, "collected")
      assert collected.meta.hermitscale.frames == []
      assert length(collected.meta.hermitscale.collected) == 3

      facts = Workflow.productions(executed, "joined")
      assert length(Enum.uniq_by(facts, & &1.hash)) == 3

      for fact <- facts do
        assert length(fact.meta.hermitscale.parents) == 2
        [left, right] = fact.meta.hermitscale.joined
        assert left.node == "left"
        assert right.node == "right"

        assert hd(left.metadata.hermitscale.frames).item ==
                 hd(right.metadata.hermitscale.frames).item
      end
    end

    test "joins never pair opposite item arrivals and partial replay preserves pending groups" do
      base = branch_workflow_fixture()

      partial =
        base
        |> Workflow.plan_eagerly([1, 2])
        |> advance_branches()

      {partial, arrivals} = Workflow.prepare_for_dispatch(partial)

      arrivals =
        Enum.sort_by(arrivals, fn runnable ->
          [frame] = runnable.input_fact.meta.hermitscale.frames
          {producer, _source} = runnable.input_fact.ancestry
          parent = Map.fetch!(partial.graph.vertices, producer)
          {parent.name, frame.index}
        end)

      [left_zero, left_one, right_zero, right_one] = arrivals

      waiting =
        Enum.reduce([left_zero, right_one], partial, fn runnable, workflow ->
          Workflow.apply_runnable(workflow, Invokable.execute(runnable.node, runnable))
        end)

      assert Workflow.raw_productions(waiting, "joined") == []

      replayed = Workflow.apply_events(base, Enum.reverse(waiting.uncommitted_events))

      completed =
        Enum.reduce([left_one, right_zero], replayed, fn runnable, workflow ->
          Workflow.apply_runnable(workflow, Invokable.execute(runnable.node, runnable))
        end)
        |> Workflow.react_until_satisfied()

      assert Workflow.raw_productions(completed, "collected") == [[[2, 10], [3, 20]]]
      assert length(Workflow.productions(completed, "joined")) == 2
    end

    test "empty and nil collections close their scope with an empty aggregate" do
      for input <- [[], nil] do
        executed =
          Workflow.react_until_satisfied(
            empty_collection_workflow_fixture(),
            Runic.Workflow.Fact.new(value: input)
          )

        assert Workflow.raw_productions(executed, "collected") == [[]]
        [output] = Workflow.productions(executed, "collected")
        assert output.meta.hermitscale.collected == []
        assert output.meta.hermitscale.frames == []
        assert output.meta.hermitscale.status == :ok
      end
    end

    test "a scalar collection input fails explicitly" do
      node = FanOut.new("items$fan_out", "items")
      fact = Runic.Workflow.Fact.new(value: 17)
      {:ok, runnable} = Invokable.prepare(node, Workflow.new(), fact)

      assert %{status: :failed, error: {:expected_collection, 17}} =
               Invokable.execute(node, runnable)
    end

    test "nested collection completion restores each enclosing occurrence including empty children" do
      base = nested_collection_workflow_fixture()
      executed = Workflow.react_until_satisfied(base, [[1, 2], [], [1, 2]], async: true)

      assert Workflow.raw_productions(executed, "outer$collected") == [[[1, 2], [], [1, 2]]]
      inner = Workflow.productions(executed, "inner$collected")
      assert length(inner) == 3
      assert length(Enum.uniq_by(inner, & &1.hash)) == 3
      assert Enum.sort(Enum.map(inner, &hd(&1.meta.hermitscale.frames).index)) == [0, 1, 2]

      restored =
        Workflow.from_events(
          Workflow.build_log(base) ++ Enum.reverse(executed.uncommitted_events)
        )

      assert Workflow.raw_productions(restored, "outer$collected") == [[[1, 2], [], [1, 2]]]

      assert Enum.sort_by(Workflow.productions(restored, "inner$collected"), & &1.hash) ==
               Enum.sort_by(inner, & &1.hash)
    end

    test "empty outer collections remain empty through a nested map" do
      executed = Workflow.react_until_satisfied(nested_collection_workflow_fixture(), [])

      [inner] = Workflow.productions(executed, "inner$collected")
      assert inner.meta.hermitscale.status == :empty
      assert Workflow.raw_productions(executed, "outer$collected") == [[]]
    end

    test "an explicitly skipped collection stays skipped after scope closure" do
      fact = Runic.Workflow.Fact.new(value: [1, 2])
      metadata = Metadata.initialize(fact)
      metadata = Metadata.put_state(metadata, %{Metadata.state(metadata) | status: :skipped})

      executed =
        Workflow.react_until_satisfied(empty_collection_workflow_fixture(), %{
          fact
          | meta: metadata
        })

      [output] = Workflow.productions(executed, "collected")
      assert output.value == []
      assert output.meta.hermitscale.status == :skipped
      assert output.meta.hermitscale.frames == []
    end

    test "repeated accepted arrivals do not publish duplicate join results" do
      base = branch_workflow_fixture()
      partial = base |> Workflow.plan_eagerly([1]) |> advance_branches()
      {partial, arrivals} = Workflow.prepare_for_dispatch(partial)
      completed = Enum.map(arrivals, &Invokable.execute(&1.node, &1))

      executed =
        Enum.reduce(completed ++ completed, partial, &Workflow.apply_runnable(&2, &1))
        |> Workflow.react_until_satisfied()

      assert Workflow.raw_productions(executed, "collected") == [[[2, 10]]]
      assert length(Workflow.productions(executed, "joined")) == 1
    end

    test "one late duplicate receipt cannot reopen a completed item join" do
      base = branch_workflow_fixture()
      partial = base |> Workflow.plan_eagerly([1]) |> advance_branches()
      {partial, arrivals} = Workflow.prepare_for_dispatch(partial)
      completed = Enum.map(arrivals, &Invokable.execute(&1.node, &1))

      executed =
        Enum.reduce(completed, partial, &Workflow.apply_runnable(&2, &1))
        |> Workflow.react_until_satisfied()

      late = Workflow.apply_runnable(executed, hd(completed))

      assert Engine.completion(late) == :ok
      assert Workflow.raw_productions(late, "collected") == [[[2, 10]]]
      assert length(Workflow.productions(late, "joined")) == 1
    end
  end

  defp advance_branches(workflow) do
    {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

    {coordination, branches} =
      Enum.split_with(runnables, &(match?(%Join{}, &1.node) or match?(%Collect{}, &1.node)))

    if branches == [] do
      assert coordination != []
      workflow
    else
      branches
      |> Enum.reduce(workflow, fn runnable, workflow ->
        Workflow.apply_runnable(workflow, Invokable.execute(runnable.node, runnable))
      end)
      |> advance_branches()
    end
  end
end
