defmodule Hermitscale.Workflows.Nodes.ExpressionReduceProbe.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "test.expression_reduce_probe",
    version: 1,
    kind: :reduce,
    inputs: [:main],
    outputs: [:main],
    expr: [:value],
    params: [
      initial: [type: :any, default: 0, doc: "Static seed accumulator (not an expression)."],
      value: [
        type: :any,
        default: nil,
        doc:
          "Per-element contribution; becomes the next accumulator. May use {{ $acc }} / {{ $json }}."
      ]
    ]

  @impl true
  def work(params, _element, _deps) do
    # The resolved `value` expression becomes the next accumulator.
    params.value
  end
end
