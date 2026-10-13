defmodule Hermitscale.Workflows.Nodes.Reviews.Request.V1 do
  @moduledoc "Waits for a durable human decision over an exact action digest."
  use Hermitscale.Workflows.Nodes.External,
    id: "reviews.request",
    version: 1,
    kind: :step,
    expr: [:action, :target_digest, :target, :reviewer_policy],
    params: [
      action: [type: :string, required: true],
      target_digest: [type: :string, required: true],
      target: [type: :map, default: %{}],
      reviewer_policy: [type: :map, default: %{}],
      policy_revision: [type: :pos_integer, default: 1],
      timeout_seconds: [type: :pos_integer, default: 3600]
    ]
end
