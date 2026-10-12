defmodule Hermitscale.Workflows.CollectionScopesTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Workflows.CollectionScopes
  alias Hermitscale.Workflows.Catalog

  describe "analyze/2" do
    test "preserves one collection scope through unequal branch depths and an explicit join" do
      graph = graph(["source", "map", "left", "right", "right_next", "join", "reduce"])

      graph =
        connect(graph, [
          {"source", "map"},
          {"map", "left"},
          {"map", "right"},
          {"right", "right_next"},
          {"left", "join"},
          {"right_next", "join"},
          {"join", "reduce"}
        ])

      kinds = %{"map" => :map, "join" => :join, "reduce" => :reduce}
      assert {:ok, scopes} = CollectionScopes.analyze(graph, kinds)
      assert scopes["join"] == %{input: ["map"], output: ["map"], map: "map"}
      assert scopes["reduce"] == %{input: ["map"], output: [], map: "map"}
    end

    test "nested reductions close their innermost collection" do
      graph =
        ["source", "outer", "inner", "inner_reduce", "outer_reduce", "after"]
        |> graph()
        |> connect([
          {"source", "outer"},
          {"outer", "inner"},
          {"inner", "inner_reduce"},
          {"inner_reduce", "outer_reduce"},
          {"outer_reduce", "after"}
        ])

      kinds = %{
        "outer" => :map,
        "inner" => :map,
        "inner_reduce" => :reduce,
        "outer_reduce" => :reduce
      }

      assert {:ok, scopes} = CollectionScopes.analyze(graph, kinds)

      assert scopes["inner_reduce"] == %{
               input: ["outer", "inner"],
               output: ["outer"],
               map: "inner"
             }

      assert scopes["outer_reduce"] == %{input: ["outer"], output: [], map: "outer"}
      assert scopes["after"] == %{input: [], output: [], map: nil}
    end

    test "rejects a join across unrelated collection scopes" do
      graph =
        ["source", "left_map", "right_map", "join"]
        |> graph()
        |> connect([
          {"source", "left_map"},
          {"source", "right_map"},
          {"left_map", "join"},
          {"right_map", "join"}
        ])

      assert {:error, issues} =
               CollectionScopes.analyze(graph, %{
                 "left_map" => :map,
                 "right_map" => :map,
                 "join" => :join
               })

      assert Enum.any?(issues, &(&1.code == :mixed_collection_scopes))
    end

    test "requires an explicit join when branches converge" do
      graph = graph(["left", "right", "step"]) |> connect([{"left", "step"}, {"right", "step"}])

      assert {:error, issues} = CollectionScopes.analyze(graph, %{})
      assert Enum.any?(issues, &(&1.code == :implicit_join))
    end

    test "requires a reduce to have exactly one parent inside a map" do
      graph = graph(["source", "reduce"]) |> connect([{"source", "reduce"}])

      assert {:error, issues} = CollectionScopes.analyze(graph, %{"reduce" => :reduce})
      assert Enum.any?(issues, &(&1.code == :reduce_without_map))

      graph =
        graph(["left", "right", "reduce"]) |> connect([{"left", "reduce"}, {"right", "reduce"}])

      assert {:error, issues} = CollectionScopes.analyze(graph, %{"reduce" => :reduce})
      assert Enum.any?(issues, &(&1.code == :reduce_parent_count))
    end
  end

  describe "issues/3" do
    test "unresolved catalog nodes leave catalog diagnostics to the validator" do
      assert [] = CollectionScopes.issues([%{"id" => "source"}], Catalog.index(), [])
    end
  end

  defp graph(ids), do: %{"nodes" => Enum.map(ids, &%{"id" => &1}), "connections" => []}

  defp connect(graph, pairs) do
    %{
      graph
      | "connections" => Enum.map(pairs, fn {from, to} -> %{"from" => from, "to" => to} end)
    }
  end
end
