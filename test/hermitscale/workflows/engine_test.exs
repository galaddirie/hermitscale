defmodule Hermitscale.Workflows.EngineTest do
  use ExUnit.Case, async: true

  import Hermitscale.WorkflowsFixtures

  alias Hermitscale.Workflows.{Compiler, Engine}
  alias Runic.Workflow
  alias Runic.Workflow.Invokable

  describe "application projections" do
    test "equal submissions retain distinct input occurrences, including nil" do
      first = Engine.input(nil, "run-1")
      second = Engine.input(nil, "run-2")
      assert first.value == second.value
      refute first.hash == second.hash
      assert first.hash == Engine.input(nil, "run-1").hash

      base = map_reduce_graph() |> Compiler.compile!()
      executed = Workflow.react_until_satisfied(base, first)
      assert Engine.productions(executed, "mapper") == []
      assert Engine.productions(executed, "summer") == [0]
      assert Engine.completion(executed) == :ok
    end

    test "a pending correlated join cannot be reported as successful completion" do
      workflow =
        valid_join_graph()
        |> Compiler.compile!()
        |> Workflow.react(%{"id" => 1})
        |> Workflow.react()

      [left] = Workflow.productions(workflow, "inventory")
      join = Workflow.get_component!(workflow, "decide$join")
      {:ok, runnable} = Invokable.prepare(join, workflow, left)
      partial = Workflow.apply_runnable(workflow, Invokable.execute(join, runnable))

      assert Engine.completion(partial) ==
               {:error, %{"reason" => "incomplete_collection", "nodes" => ["decide$join"]}}
    end
  end
end
