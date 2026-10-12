defmodule Hermitscale.Workflows.Nodes.GitHub.Users.GetIssues.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :users_get_issues
end
