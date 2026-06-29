defmodule Hermitscale.Workflows.Nodes.JoinProbe.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "test.join_probe",
    version: 1,
    kind: :join,
    inputs: [:left, :right],
    outputs: [:main]

  @impl true
  def work(_params, main, _deps) do
    # `main` is the ordered list of the join's parent values (`$json`).
    %{merged: main}
  end
end
