defmodule Hermitscale.Workflows.Nodes.PrimitivesTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Workflows.Compiler
  alias Hermitscale.Workflows.Nodes.Builtin.Merge.V1, as: Merge
  alias Runic.Workflow

  defp compile_and_run(graph, input) do
    assert {:ok, workflow} = Compiler.compile(graph)

    workflow
    |> Workflow.react_until_satisfied(input)
    |> Workflow.raw_productions()
  end

  describe "map node" do
    test "evaluates value per element over a bare list" do
      graph = %{
        "schema_version" => 1,
        "id" => "wf_map",
        "name" => "map",
        "nodes" => [
          %{"id" => "source", "type" => "test.identity_probe", "version" => 1, "params" => %{}},
          %{
            "id" => "double",
            "type" => "map",
            "version" => 1,
            "params" => %{"value" => "{{ $json.n | times: 2 }}"}
          }
        ],
        "connections" => [%{"from" => "source", "to" => "double"}]
      }

      results = compile_and_run(graph, [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}])

      assert 2 in results
      assert 4 in results
      assert 6 in results
    end
  end

  describe "reduce node" do
    test "folds mapped elements with $acc and a static seed" do
      graph = %{
        "schema_version" => 1,
        "id" => "wf_reduce",
        "name" => "reduce",
        "nodes" => [
          %{"id" => "source", "type" => "test.identity_probe", "version" => 1, "params" => %{}},
          %{
            "id" => "values",
            "type" => "map",
            "version" => 1,
            "params" => %{"value" => "{{ $json.n }}"}
          },
          %{
            "id" => "sum",
            "type" => "reduce",
            "version" => 1,
            "params" => %{"initial" => 0, "value" => "{{ $acc | plus: $json }}"}
          }
        ],
        "connections" => [
          %{"from" => "source", "to" => "values"},
          %{"from" => "values", "to" => "sum"}
        ]
      }

      results = compile_and_run(graph, [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}])

      assert 6 in results
    end
  end

  describe "merge node" do
    test "append mode emits the ordered list of joined inputs" do
      input = %{"x" => 1}

      graph = %{
        "schema_version" => 1,
        "id" => "wf_merge",
        "name" => "merge",
        "nodes" => [
          %{"id" => "validate", "type" => "test.identity_probe", "version" => 1, "params" => %{}},
          %{"id" => "a", "type" => "test.identity_probe", "version" => 1, "params" => %{}},
          %{"id" => "b", "type" => "test.identity_probe", "version" => 1, "params" => %{}},
          %{
            "id" => "merged",
            "type" => "merge",
            "version" => 1,
            "params" => %{"mode" => "append"}
          }
        ],
        "connections" => [
          %{"from" => "validate", "to" => "a"},
          %{"from" => "validate", "to" => "b"},
          %{"from" => "a", "to" => "merged", "to_input" => 0},
          %{"from" => "b", "to" => "merged", "to_input" => 1}
        ]
      }

      results = compile_and_run(graph, input)

      assert Enum.any?(results, &match?([^input, ^input], &1))
    end

    test "combine mode shallow-merges map inputs" do
      assert Merge.work(%{mode: "combine"}, [%{"a" => 1}, %{"b" => 2}], %{}) ==
               %{"a" => 1, "b" => 2}
    end
  end
end
