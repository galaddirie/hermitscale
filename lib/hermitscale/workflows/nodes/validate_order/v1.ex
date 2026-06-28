defmodule Hermitscale.Workflows.Nodes.ValidateOrder.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour
  require Runic

  @impl true
  def spec do
    %{
      id: "validate_order",
      version: 1,
      kind: :step,
      inputs: [:main],
      outputs: [:main],
      params_schema: [],
      deprecated: false
    }
  end

  @impl true
  def build(_params, ctx) do
    name = ctx.name

    Runic.step(fn input -> input end, name: name)
  end
end
