defmodule Hermitscale.Workflows.Nodes.Agents.PublishBranch.V1 do
  @moduledoc "Commits an explicit manifest and waits for verification of the remote branch."
  use Hermitscale.Workflows.Nodes.External,
    id: "agents.publish_branch",
    version: 1,
    kind: :step,
    expr: [
      :session_id,
      :branch,
      :base_sha,
      :manifest,
      :message,
      :candidate_digest,
      :patch_snapshot_artifact_id,
      :review_id
    ],
    params: [
      session_id: [type: :string, required: true],
      branch: [type: :string, required: true],
      base_sha: [type: :string, required: true],
      manifest: [type: {:list, :string}, required: true],
      message: [type: :string, required: true],
      candidate_digest: [type: :string, required: true],
      patch_snapshot_artifact_id: [
        type: :string,
        required: true,
        doc: "ID of the host-verified patch_snapshot artifact."
      ],
      review_id: [type: :string],
      policy_revision: [type: :pos_integer, default: 1]
    ]
end
