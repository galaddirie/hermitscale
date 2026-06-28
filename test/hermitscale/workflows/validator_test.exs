defmodule Hermitscale.Workflows.ValidatorTest do
  use ExUnit.Case, async: true

  import Hermitscale.WorkflowsFixtures

  alias Hermitscale.Workflows.Validator

  describe "validate/1" do
    test "accepts a valid graph" do
      assert :ok = Validator.validate(valid_join_graph())
    end

    test "returns all structural issues" do
      graph =
        valid_join_graph(%{
          "nodes" => [
            %{"id" => "validate", "type" => "missing", "version" => 1, "params" => %{}},
            %{"id" => "validate", "type" => "validate_order", "version" => 1, "params" => %{}}
          ],
          "connections" => [%{"from" => "validate", "to" => "missing"}]
        })

      assert {:error, issues} = Validator.validate(graph)
      assert Enum.any?(issues, &(&1.code == :duplicate_node_id))
      assert Enum.any?(issues, &(&1.code == :unknown_catalog_node))
      assert Enum.any?(issues, &(&1.code == :missing_node))
    end

    test "rejects non-contiguous join slots" do
      graph =
        valid_join_graph(%{
          "connections" => [
            %{"from" => "validate", "to" => "inventory"},
            %{"from" => "validate", "to" => "fraud"},
            %{"from" => "inventory", "to" => "decide", "to_input" => 1},
            %{"from" => "fraud", "to" => "decide", "to_input" => 1}
          ]
        })

      assert {:error, issues} = Validator.validate(graph)
      assert Enum.any?(issues, &(&1.code == :join_input_slots))
    end
  end
end
