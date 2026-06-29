defmodule Hermitscale.Workflows.Nodes.ExpressionProbe.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "test.expression_probe",
    version: 1,
    kind: :step,
    inputs: [:main],
    outputs: [:main],
    expr: [:count, :message, :payload],
    params: [
      count: [type: :any, default: nil, doc: "Resolved count."],
      message: [type: :any, default: nil, doc: "Resolved message."],
      payload: [type: :any, default: nil, doc: "Resolved payload."]
    ]

  @impl true
  def work(params, input, _deps) do
    %{
      input: input,
      params: params
    }
  end
end
