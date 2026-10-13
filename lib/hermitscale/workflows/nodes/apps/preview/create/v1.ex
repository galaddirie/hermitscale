defmodule Hermitscale.Workflows.Nodes.Apps.Preview.Create.V1 do
  @moduledoc "Starts an authorized preview without completing until its URL is verified."
  use Hermitscale.Workflows.Nodes.External,
    id: "apps.preview.create",
    version: 1,
    kind: :step,
    expr: [:app_id, :session_id, :source_revision, :configuration],
    params: [
      app_id: [type: :string, required: true],
      session_id: [type: :string, required: true],
      source_revision: [type: :string, required: true],
      configuration: [type: :map, default: %{}]
    ]
end
