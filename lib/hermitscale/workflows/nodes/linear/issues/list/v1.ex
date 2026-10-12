defmodule Hermitscale.Workflows.Nodes.Linear.Issues.List.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.Linear.Operations,
    operation: :issues_list
end
