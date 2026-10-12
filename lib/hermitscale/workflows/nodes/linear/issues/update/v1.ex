defmodule Hermitscale.Workflows.Nodes.Linear.Issues.Update.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.Linear.Operations,
    operation: :issues_update
end
