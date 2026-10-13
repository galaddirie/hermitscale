defmodule Hermitscale.Workflows.Nodes.Apps.Logs.Read.V1 do
  @moduledoc "Collects a bounded authorized log snapshot as an explicit workspace operation."
  use Hermitscale.Workflows.Nodes.External,
    id: "apps.logs.read",
    version: 1,
    kind: :step,
    expr: [:app_id, :environment_id],
    params: [
      app_id: [type: :string, required: true],
      environment_id: [type: :string],
      limit: [type: :pos_integer, default: 100],
      max_bytes: [type: :pos_integer, default: 65536],
      wake: [type: :boolean, default: false]
    ]
end
