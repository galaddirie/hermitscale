defmodule Hermitscale.Workflows.Nodes.MergeDecision.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour
  require Runic

  @impl true
  def spec do
    %{
      id: "merge_decision",
      version: 1,
      kind: :join,
      inputs: [:left, :right],
      outputs: [:main],
      params_schema: [],
      deprecated: false
    }
  end

  @impl true
  def build(_params, ctx) do
    inputs = ctx.inputs
    name = ctx.name

    Runic.step(fn left, right -> %{inputs: ^inputs, left: left, right: right} end, name: name)
  end
end
