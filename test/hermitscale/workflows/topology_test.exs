defmodule Hermitscale.Workflows.TopologyTest do
  use ExUnit.Case, async: true

  import Hermitscale.WorkflowsFixtures

  alias Hermitscale.Workflows.Topology

  describe "structural relationships" do
    test "preserves parent input slots and child declaration order" do
      graph = valid_join_graph()

      assert Topology.parent_map(Enum.reverse(graph["connections"]))["decide"] == [
               "inventory",
               "fraud"
             ]

      assert Topology.child_map(graph["connections"])["validate"] == ["inventory", "fraud"]

      assert Topology.ancestor_map(graph["nodes"], graph["connections"])["decide"] ==
               MapSet.new(["validate", "inventory", "fraud"])
    end
  end

  describe "order/1" do
    test "orders every parent before its children" do
      graph = valid_join_graph()
      assert {:ok, order} = Topology.order(graph)
      indexes = order |> Enum.with_index() |> Map.new()

      for %{"from" => from, "to" => to} <- graph["connections"] do
        assert Map.fetch!(indexes, from) < Map.fetch!(indexes, to)
      end
    end

    test "reports cycles" do
      graph = valid_join_graph()
      graph = Map.update!(graph, "connections", &[%{"from" => "decide", "to" => "validate"} | &1])

      assert {:error, :cycle} = Topology.order(graph)
    end
  end
end
