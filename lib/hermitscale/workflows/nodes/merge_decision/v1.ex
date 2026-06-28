defmodule Hermitscale.Workflows.Nodes.MergeDecision.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "merge_decision",
    version: 1,
    kind: :join,
    inputs: [:left, :right],
    outputs: [:main]

  require Runic

  @impl true
  def build(_params, %{inputs: inputs, name: name}) do
    Runic.step(fn left, right -> %{inputs: ^inputs, left: left, right: right} end, name: name)
  end
end
