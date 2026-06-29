defmodule Hermitscale.Workflows.Nodes.IdentityProbe.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "test.identity_probe",
    version: 1,
    kind: :step,
    inputs: [:main],
    outputs: [:main]

  @impl true
  def work(_params, input, _deps), do: input
end
