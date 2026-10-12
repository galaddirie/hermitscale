defmodule Hermitscale.Workflows.Nodes.GitHub.Workflows.Dispatch.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :workflows_dispatch
end
