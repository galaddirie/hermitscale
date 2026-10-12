defmodule Hermitscale.Workflows.Nodes.GitHub.PullRequests.Get.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :pull_requests_get
end
