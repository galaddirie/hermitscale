defmodule Hermitscale.Workflows.Nodes.GitHub.Issues.Create.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :issues_create
end
