defmodule Hermitscale.Workflows.Nodes.ExpressionMapProbe.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "test.expression_map_probe",
    version: 1,
    kind: :map,
    inputs: [:main],
    outputs: [:main],
    expr: [:label, :value],
    params: [
      label: [type: :any, default: nil, doc: "Resolved per-element label."],
      value: [type: :any, default: nil, doc: "Resolved per-element value."]
    ]

  @impl true
  def work(params, element, _deps) do
    %{element: element, params: params}
  end
end
