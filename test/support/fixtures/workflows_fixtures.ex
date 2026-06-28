defmodule Hermitscale.WorkflowsFixtures do
  @moduledoc """
  Test fixtures for workflow graph definitions.
  """

  def valid_join_graph(attrs \\ %{}) do
    attrs = Map.new(attrs)

    Map.merge(
      %{
        "schema_version" => 1,
        "id" => "wf_order_fulfillment",
        "name" => "order_fulfillment",
        "nodes" => [
          %{"id" => "validate", "type" => "validate_order", "version" => 1, "params" => %{}},
          %{"id" => "inventory", "type" => "validate_order", "version" => 1, "params" => %{}},
          %{"id" => "fraud", "type" => "validate_order", "version" => 1, "params" => %{}},
          %{"id" => "decide", "type" => "merge_decision", "version" => 1, "params" => %{}}
        ],
        "connections" => [
          %{"from" => "validate", "to" => "inventory"},
          %{"from" => "validate", "to" => "fraud"},
          %{"from" => "inventory", "to" => "decide", "to_input" => 0},
          %{"from" => "fraud", "to" => "decide", "to_input" => 1}
        ]
      },
      attrs
    )
  end

  def graph_attrs(attrs \\ %{}) do
    attrs = Map.new(attrs)
    definition = valid_join_graph()

    Map.merge(
      %{
        id: definition["id"],
        name: definition["name"],
        schema_version: definition["schema_version"],
        definition: definition,
        status: :active
      },
      attrs
    )
  end
end
