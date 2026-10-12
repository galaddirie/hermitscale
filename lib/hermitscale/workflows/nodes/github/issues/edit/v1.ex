defmodule Hermitscale.Workflows.Nodes.GitHub.Issues.Edit.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :issues_edit
end
