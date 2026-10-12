defmodule Hermitscale.Workflows.Nodes.GitHub.Workflows.Disable.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :workflows_disable
end
