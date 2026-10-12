defmodule Hermitscale.Workflows.Nodes.GitHub.Repositories.GetPullRequests.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :repositories_get_pull_requests
end
