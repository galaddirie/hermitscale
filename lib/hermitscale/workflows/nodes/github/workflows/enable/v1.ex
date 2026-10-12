defmodule Hermitscale.Workflows.Nodes.GitHub.Workflows.Enable.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :workflows_enable
end
