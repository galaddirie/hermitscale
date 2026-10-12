defmodule Hermitscale.Workflows.Nodes.ContextReduceProbe.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "test.context_reduce_probe",
    version: 1,
    kind: :reduce,
    requires: [observer: []],
    expr: [:value],
    params: [
      initial: [type: :any, default: 0],
      value: [type: :any, default: nil],
      metadata: [type: :any, default: %{}]
    ]

  @impl true
  def work(params, _input, %{observer: observer, context: context}) do
    send(observer, {:reduce_context, context})

    Runic.Workflow.SingleOutput.Result.value(params.value,
      metadata: Map.get(params, :metadata, %{})
    )
  end
end
