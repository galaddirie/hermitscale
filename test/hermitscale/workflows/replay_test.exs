defmodule Hermitscale.Workflows.ReplayTest do
  use ExUnit.Case, async: true

  import Hermitscale.WorkflowsFixtures

  require Runic

  alias Hermitscale.Workflows.{Compiler, Replay}
  alias Runic.Workflow

  describe "restore/2" do
    test "scheduler matcher fingerprints survive independent compilation" do
      graph = failing_math_graph()
      first = Compiler.compile!(graph)
      second = Compiler.compile!(graph)
      assert Replay.definition_event(first) == Replay.definition_event(second)
      assert {:ok, _workflow} = Replay.restore([Replay.definition_event(first)], second)
    end

    test "completed map work is replayed without repeating accepted mapper effects" do
      base =
        Workflow.new()
        |> Workflow.add(
          Runic.map(
            fn x ->
              send(self(), {:mapped, x})
              x * 2
            end,
            name: :items
          )
        )
        |> Workflow.add(Runic.reduce(0, fn x, acc -> x + acc end, name: :sum), to: :items)
        |> Workflow.enable_event_emission()

      partial = base |> Workflow.react([1, 2, 3], []) |> Workflow.react()

      assert_receive {:mapped, 1}
      assert_receive {:mapped, 2}
      assert_receive {:mapped, 3}
      assert Workflow.raw_productions(partial, :sum) == []

      events = Enum.reverse(partial.uncommitted_events)

      assert {:ok, restored} =
               Replay.restore(
                 [Replay.definition_event(base) | Workflow.build_log(base) ++ events],
                 base
               )

      completed = Workflow.react_until_satisfied(restored)
      assert Workflow.raw_productions(completed, :sum) == [12]
      refute_receive {:mapped, _}
    end

    test "old vendor component identities are rejected before replay" do
      base = Compiler.compile!(map_reduce_graph())
      event = %Runic.Workflow.ComponentAdded{name: "mapper", hash: 123}

      assert {:error, :incompatible_workflow_events} =
               Replay.restore([Replay.definition_event(base), event], base)
    end

    test "accepted events from a changed compiled definition are rejected" do
      base = Compiler.compile!(map_reduce_graph()) |> Workflow.enable_event_emission()
      partial = Workflow.react(base, [%{"n" => 1}], [])
      graph = map_reduce_graph()

      nodes =
        Enum.map(graph["nodes"], fn
          %{"id" => "source"} = node ->
            %{node | "type" => "test.authoring_probe", "params" => %{"count" => 2}}

          node ->
            node
        end)

      changed = Compiler.compile!(%{graph | "nodes" => nodes})

      assert {:error, :incompatible_workflow_events} =
               Replay.restore(
                 [Replay.definition_event(base) | Enum.reverse(partial.uncommitted_events)],
                 changed
               )
    end

    test "rewiring changes component dependencies and rejects old history" do
      graph = rewirable_map_reduce_graph()
      base = Compiler.compile!(graph) |> Workflow.enable_event_emission()
      partial = Workflow.react(base, :start, [])
      events = [Replay.definition_event(base) | Enum.reverse(partial.uncommitted_events)]

      changed_graph =
        put_in(graph["connections"], [
          %{"from" => "b", "to" => "mapper"},
          %{"from" => "mapper", "to" => "sum"}
        ])

      changed = Compiler.compile!(changed_graph)
      refute base.components == changed.components
      assert base.components["a"] == changed.components["a"]
      assert base.components["b"] == changed.components["b"]
      assert {:error, :incompatible_workflow_events} = Replay.restore(events, changed)

      assert {:ok, restored} = Replay.restore(events, Compiler.compile!(graph))
      assert Workflow.raw_productions(Workflow.react_until_satisfied(restored), "sum") == [10]

      assert Workflow.raw_productions(Workflow.react_until_satisfied(changed, :start), "sum") == [
               20
             ]
    end

    test "histories without a definition record are rejected" do
      base = Compiler.compile!(map_reduce_graph()) |> Workflow.enable_event_emission()
      partial = Workflow.react(base, [%{"n" => 1}], [])

      assert {:error, :incompatible_workflow_events} =
               Replay.restore(Enum.reverse(partial.uncommitted_events), base)
    end

    test "legacy graph snapshots and removed event modules are rejected" do
      base = Compiler.compile!(map_reduce_graph())
      snapshot = %Runic.Workflow.ReactionOccurred{reaction: :produced}
      legacy = %{__struct__: Hermitscale.Workflows.RemovedVendorEvent}

      record = Replay.definition_event(base)
      assert {:error, :incompatible_workflow_events} = Replay.restore([record, snapshot], base)
      assert {:error, :incompatible_workflow_events} = Replay.restore([record, legacy], base)
    end
  end
end
