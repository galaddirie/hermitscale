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

      assert Enum.any?(results, &match?(%{merged: [^input, ^input]}, &1))
    end

    test "returns validation errors for invalid graph JSON" do
      graph = valid_join_graph(%{"nodes" => []})

      assert {:error, issues} = Compiler.compile(graph)
      assert Enum.any?(issues, &(&1.code == :missing_node))
    end

    test "casts params and merges graph policy over node default policy" do
      input = %{"source" => "test"}

      graph =
        authoring_probe_graph(%{
          "nodes" => [
            %{
              "id" => "probe",
              "type" => "test.authoring_probe",
              "version" => 1,
              "params" => %{"count" => 2},
              "policy" => %{"max_retries" => 5}
            }
          ]
        })

      assert {:ok, workflow} = Compiler.compile(graph)
      assert [{{:name, name_matcher}, policy}] = workflow.scheduler_policies
      assert Regex.match?(name_matcher, "probe")
      assert %{backoff: :linear, max_retries: 5, timeout_ms: 10} = policy

      results =
        workflow
        |> Workflow.react_until_satisfied(input)
        |> Workflow.raw_productions()

      assert Enum.any?(
               results,
               &match?(%{authoring_probe: %{count: 2, flag: false}}, &1)
             )
    end

    test "resolves expression params with json, env, and upstream node context" do
      input = %{"count" => "7", "email" => "person@example.test", "id" => 42}

      assert {:ok, workflow} = Compiler.compile(expression_probe_graph())

      results =
        workflow
        |> Workflow.react_until_satisfied(input)
        |> Workflow.raw_productions()

      assert Enum.any?(results, fn
               %{
                 params: %{
                   count: 7,
                   message: "https://api.example.test/users/42",
                   payload: %{"count" => 7, "email" => "person@example.test"}
                 }
               } ->
                 true

               _other ->
                 false
             end)
    end

    test "fans a map over a bare list, resolving per-element expressions" do
      input = [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}]

      assert {:ok, workflow} = Compiler.compile(map_probe_graph())

      results =
        workflow
        |> Workflow.react_until_satisfied(input)
        |> Workflow.raw_productions()

      for {n, value} <- [{1, 10}, {2, 20}, {3, 30}] do
        assert Enum.any?(
                 results,
                 &match?(
                   %{element: %{"n" => ^n}, params: %{value: ^value, label: "item-" <> _}},
                   &1
                 )
               )
      end
    end

    test "reduces mapped elements into a bare accumulator with a static seed" do
      input = [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}]

      assert {:ok, workflow} = Compiler.compile(map_reduce_graph())

      results =
        workflow
        |> Workflow.react_until_satisfied(input)
        |> Workflow.raw_productions()

      # value = $json.n * 10 per element; reduce sums via {{ $acc | plus: ... }}.
      assert 60 in results
    end

    test "delivers $node references into a map via an added edge (zip path)" do
      input = [%{"n" => 1}, %{"n" => 2}]

      assert {:ok, workflow} = Compiler.compile(node_ref_map_graph())

      results =
        workflow
        |> Workflow.react_until_satisfied(input)
        |> Workflow.raw_productions()

      # label resolves {{ $node["ctx_src"].json | size }} = 2 for every element.
      for n <- [1, 2] do
        assert Enum.any?(
                 results,
                 &match?(%{element: %{"n" => ^n}, params: %{value: ^n, label: 2}}, &1)
               )
      end
    end
  end
end
