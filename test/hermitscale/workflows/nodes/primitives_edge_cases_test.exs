defmodule Hermitscale.Workflows.Nodes.PrimitivesEdgeCasesTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Workflows.Compiler
  alias Hermitscale.Workflows.Nodes.Merge.V1, as: Merge
  alias Runic.Workflow

  defp node(id, type, params),
    do: %{"id" => id, "type" => type, "version" => 1, "params" => params}

  defp graph(nodes, connections, extra \\ %{}) do
    Map.merge(
      %{
        "schema_version" => 1,
        "id" => "wf_edge",
        "name" => "wf_edge",
        "nodes" => nodes,
        "connections" => connections
      },
      extra
    )
  end

  defp run(graph, input) do
    assert {:ok, workflow} = Compiler.compile(graph)

    workflow
    |> Workflow.react_until_satisfied(input)
    |> Workflow.raw_productions()
  end

  # A source that simply forwards the workflow input, then a `map`.
  defp map_graph(map_params, extra \\ %{}) do
    graph(
      [node("source", "validate_order", %{}), node("m", "map", map_params)],
      [%{"from" => "source", "to" => "m"}],
      extra
    )
  end

  # source -> map -> reduce.
  defp map_reduce_graph(map_params, reduce_params, extra \\ %{}) do
    graph(
      [
        node("source", "validate_order", %{}),
        node("m", "map", map_params),
        node("r", "reduce", reduce_params)
      ],
      [%{"from" => "source", "to" => "m"}, %{"from" => "m", "to" => "r"}],
      extra
    )
  end

  describe "map / expressions" do
    test "empty list produces no element outputs" do
      results = run(map_graph(%{"value" => "{{ $json.n | times: 2 }}"}), [])
      assert Enum.all?(results, &(&1 == []))
    end

    test "single element list" do
      results = run(map_graph(%{"value" => "{{ $json.n | times: 2 }}"}), [%{"n" => 21}])
      assert 42 in results
    end

    test "lone-object value resolves to a real (typed) integer, not a string" do
      results = run(map_graph(%{"value" => "{{ $json.n | times: 10 }}"}), [%{"n" => 3}])

      assert 30 in results
      refute "30" in results
    end

    test "nested field access" do
      results = run(map_graph(%{"value" => "{{ $json.a.b }}"}), [%{"a" => %{"b" => "deep"}}])
      assert "deep" in results
    end

    test "missing field falls back via default filter" do
      results =
        run(map_graph(%{"value" => "{{ $json.missing | default: \"NA\" }}"}), [%{"n" => 1}])

      assert "NA" in results
    end

    test "object-of-expressions value yields a map per element" do
      results =
        run(
          map_graph(%{
            "value" => %{"doubled" => "{{ $json.n | times: 2 }}", "raw" => "{{ $json.n }}"}
          }),
          [%{"n" => 5}]
        )

      assert %{"doubled" => 10, "raw" => 5} in results
    end

    test "identity map (no value) passes elements through" do
      results = run(map_graph(%{}), [%{"n" => 1}, %{"n" => 2}])
      assert %{"n" => 1} in results
      assert %{"n" => 2} in results
    end

    test "scalar (non-list) input maps as a single element instead of crashing" do
      results = run(map_graph(%{}), 42)
      assert 42 in results
    end

    test "ambient $env resolves inside a mapped element" do
      results =
        run(
          map_graph(%{"value" => "{{ $env.API }}/{{ $json.n }}"}, %{
            "env" => %{"API" => "https://x"}
          }),
          [%{"n" => 7}]
        )

      assert "https://x/7" in results
    end
  end

  describe "reduce / expressions" do
    test "string concatenation folds in element order with an empty-string seed" do
      results =
        run(
          map_reduce_graph(
            %{"value" => "{{ $json.c }}"},
            %{"initial" => "", "value" => "{{ $acc }}{{ $json }}"}
          ),
          [%{"c" => "a"}, %{"c" => "b"}, %{"c" => "c"}]
        )

      assert "abc" in results
    end

    test "empty upstream collection produces no reduce output" do
      results =
        run(
          map_reduce_graph(
            %{"value" => "{{ $json.n }}"},
            %{"initial" => 0, "value" => "{{ $acc | plus: $json }}"}
          ),
          []
        )

      assert Enum.all?(results, &(&1 == []))
    end

    test "no value expression returns the static seed unchanged" do
      results =
        run(
          map_reduce_graph(%{"value" => "{{ $json.n }}"}, %{"initial" => "seed"}),
          [%{"n" => 1}, %{"n" => 2}]
        )

      assert "seed" in results
    end

    test "folds over mapped objects via $json field access" do
      results =
        run(
          map_reduce_graph(
            %{"value" => %{"amt" => "{{ $json.n }}"}},
            %{"initial" => 0, "value" => "{{ $acc | plus: $json.amt }}"}
          ),
          [%{"n" => 10}, %{"n" => 20}, %{"n" => 5}]
        )

      assert 35 in results
    end

    test "ambient $env is available alongside $acc and $json" do
      results =
        run(
          map_reduce_graph(
            %{"value" => "{{ $json.n }}"},
            %{"initial" => 0, "value" => "{{ $acc | plus: $json | plus: $env.BONUS }}"},
            %{"env" => %{"BONUS" => 10}}
          ),
          [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}]
        )

      # (0+1+10) -> (11+2+10) -> (23+3+10) = 36
      assert 36 in results
    end
  end

  describe "merge / modes" do
    test "append mode emits the ordered list, combine mode merges maps" do
      assert Merge.work(%{mode: "append"}, [%{"a" => 1}, %{"b" => 2}], %{}) ==
               [%{"a" => 1}, %{"b" => 2}]

      assert Merge.work(%{mode: "combine"}, [%{"a" => 1}, %{"b" => 2}], %{}) ==
               %{"a" => 1, "b" => 2}
    end

    test "combine lets later inputs win on key collisions" do
      assert Merge.work(%{mode: "combine"}, [%{"k" => "first"}, %{"k" => "second"}], %{}) ==
               %{"k" => "second"}
    end

    test "combine skips non-map inputs" do
      assert Merge.work(%{mode: "combine"}, [%{"a" => 1}, "scalar", %{"b" => 2}], %{}) ==
               %{"a" => 1, "b" => 2}
    end
  end

  describe "composition" do
    test "merge (append) output can be mapped over downstream" do
      input = %{"v" => 1}

      composed =
        graph(
          [
            node("validate", "validate_order", %{}),
            node("a", "validate_order", %{}),
            node("b", "validate_order", %{}),
            node("merged", "merge", %{"mode" => "append"}),
            node("each", "map", %{"value" => "{{ $json.v }}"})
          ],
          [
            %{"from" => "validate", "to" => "a"},
            %{"from" => "validate", "to" => "b"},
            %{"from" => "a", "to" => "merged", "to_input" => 0},
            %{"from" => "b", "to" => "merged", "to_input" => 1},
            %{"from" => "merged", "to" => "each"}
          ]
        )

      results = run(composed, input)

      # merge emits the ordered list, and mapping over it extracts the field.
      # (Runic content-dedupes identical facts, so the two identical 1s collapse.)
      assert [%{"v" => 1}, %{"v" => 1}] in results
      assert 1 in results
    end
  end
end
