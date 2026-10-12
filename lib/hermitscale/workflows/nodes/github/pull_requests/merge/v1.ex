defmodule Hermitscale.Workflows.Nodes.GitHub.PullRequests.Merge.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :pull_requests_merge
end
