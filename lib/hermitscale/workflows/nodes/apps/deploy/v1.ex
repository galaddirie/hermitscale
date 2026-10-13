defmodule Hermitscale.Workflows.Nodes.Apps.Deploy.V1 do
  @moduledoc "Requests release verification and waits for an activated app deployment."
  use Hermitscale.Workflows.Nodes.External,
    id: "apps.deploy",
    version: 1,
    kind: :step,
    expr: [
      :app_id,
      :environment_id,
      :session_id,
      :source_commit,
      :artifact_id,
      :artifact_digest,
      :configuration_digest,
      :expected_active_deployment,
      :review_id
    ],
    params: [
      app_id: [type: :string, required: true],
      environment_id: [type: :string, required: true],
      session_id: [type: :string, required: true],
      source_commit: [type: :string, required: true],
      artifact_id: [type: :string, required: true],
      artifact_digest: [type: :string, required: true],
      configuration_digest: [type: :string, required: true],
      expected_active_deployment: [type: :any],
      review_id: [type: :string]
    ]
end
