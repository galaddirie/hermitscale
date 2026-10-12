defmodule Hermitscale.Workflows.Nodes.ContextProbe.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "test.context_probe",
    version: 1,
    kind: :step,
    requires: [observer: []],
    expr: [:value],
    params: [value: [type: :any, default: nil], fail_until: [type: :non_neg_integer, default: 0]]

  @impl true
  def work(params, input, %{observer: observer, context: context}) do
    send(observer, {:engine_context, context})

    case Map.get(params, :fail_until, 0) > context.attempt_number do
      true ->
        Runic.Workflow.SingleOutput.Result.failure(:temporary)

      false ->
        case params.value do
          nil -> input
          value -> value
        end
    end
  end
end
