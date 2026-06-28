defmodule Hermitscale.Workflows.Nodes.ValidateOrder.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "validate_order",
    version: 1,
    kind: :step,
    inputs: [:main],
    outputs: [:main]

  require Runic

  @impl true
  def build(_params, %{name: name}) do
    Runic.step(fn input -> input end, name: name)
  end
end
