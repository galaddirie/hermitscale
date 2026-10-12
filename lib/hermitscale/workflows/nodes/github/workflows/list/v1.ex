defmodule Hermitscale.Workflows.Nodes.GitHub.Workflows.List.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :workflows_list
end
