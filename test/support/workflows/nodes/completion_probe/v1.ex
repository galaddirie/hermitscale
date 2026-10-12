defmodule Hermitscale.Workflows.Nodes.CompletionProbe.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "test.completion_probe",
    version: 1,
    kind: :step,
    inputs: [:main],
    outputs: [:main],
    requires: [observer: []]

  @impl true
  def work(_params, input, %{observer: observer}) do
    send(observer, {:workflow_node_waiting, self()})

    receive do
      :release -> input
    end
  end
end
