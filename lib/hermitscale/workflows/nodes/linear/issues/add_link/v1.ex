defmodule Hermitscale.Workflows.Nodes.Linear.Issues.AddLink.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.Linear.Operations,
    operation: :issues_add_link
end
