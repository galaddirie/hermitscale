defmodule Hermitscale.CollectionEngineFixtures do
  @moduledoc false

  alias Hermitscale.Workflows.Engine.{FanIn, FanOut, Join, Node}
  alias Hermitscale.Workflows.Nodes.Builtin.Math.V1, as: Math
  alias Hermitscale.Workflows.Nodes.Params
  alias Runic.Workflow

  def collection_workflow_fixture do
    Workflow.new()
    |> Workflow.add(FanOut.new("items$fan_out", "items"))
    |> Workflow.enable_event_emission()
  end

  def branch_workflow_fixture do
    left = math_node("left", "add", 1)
    middle = math_node("middle", "add", 0)
    right = math_node("right", "multiply", 10)
    join = Join.new("joined", [left.hash, right.hash])
    fan_in = FanIn.new("collected", join.hash, "items")

    collection_workflow_fixture()
    |> Workflow.add(left, to: "items$fan_out")
    |> Workflow.add(middle, to: "items$fan_out")
    |> Workflow.add(right, to: "middle")
    |> Workflow.add(join, to: ["left", "right"])
    |> Workflow.add(fan_in, to: "joined")
  end

  def empty_collection_workflow_fixture do
    fan_out = FanOut.new("items$fan_out", "items")
    fan_in = FanIn.new("collected", fan_out.hash, "items")

    Workflow.new()
    |> Workflow.add(fan_out)
    |> Workflow.add(fan_in, to: "items$fan_out")
    |> Workflow.enable_event_emission()
  end

  def nested_collection_workflow_fixture do
    outer = FanOut.new("outer$fan_out", "outer")
    inner = FanOut.new("inner$fan_out", "inner")
    inner_fan_in = FanIn.new("inner$fan_in", inner.hash, "inner")
    outer_fan_in = FanIn.new("outer$fan_in", inner_fan_in.hash, "outer")

    Workflow.new()
    |> Workflow.add(outer)
    |> Workflow.add(inner, to: outer.name)
    |> Workflow.add(inner_fan_in, to: inner.name)
    |> Workflow.add(outer_fan_in, to: inner_fan_in.name)
    |> Workflow.enable_event_emission()
  end

  defp math_node(name, operation, right) do
    params =
      Params.cast!(
        %{"operation" => operation, "left" => "{{ $json }}", "right" => right},
        Math.__catalog_node__().params_schema,
        [:left, :right]
      )

    Node.new(Math, params, %{name: name, parents: [], map: "items"})
  end
end
