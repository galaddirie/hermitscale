defmodule Hermitscale.Workflows.Nodes.Support.Investigate.V1 do
  @moduledoc "Investigates a ticket against its trusted app mapping and waits for verified evidence."
  use Hermitscale.Workflows.Nodes.External,
    id: "support.investigate",
    version: 1,
    kind: :step,
    expr: [:subscription_id, :ticket_id],
    params: [
      subscription_id: [type: :string, required: true],
      ticket_id: [type: :string, required: true],
      timeout_seconds: [type: :pos_integer, default: 1800]
    ]
end
