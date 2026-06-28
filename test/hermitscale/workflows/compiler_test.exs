defmodule Hermitscale.Workflows.CompilerTest do
  use ExUnit.Case, async: true

  import Hermitscale.WorkflowsFixtures

  alias Hermitscale.Workflows.Compiler
  alias Runic.Workflow

  describe "compile/1" do
    test "builds an executable Runic workflow from graph JSON" do
      input = %{"sku" => "ABC-123"}

      assert {:ok, workflow} = Compiler.compile(valid_join_graph())

      results =
        workflow
        |> Workflow.react_until_satisfied(input)
        |> Workflow.raw_productions()

      assert Enum.any?(
               results,
               &match?(%{left: ^input, right: ^input, inputs: ["inventory", "fraud"]}, &1)
             )
    end

    test "returns validation errors for invalid graph JSON" do
      graph = valid_join_graph(%{"nodes" => []})

      assert {:error, issues} = Compiler.compile(graph)
      assert Enum.any?(issues, &(&1.code == :missing_node))
    end
  end
end
