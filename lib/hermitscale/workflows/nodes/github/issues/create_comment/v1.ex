defmodule Hermitscale.Workflows.Nodes.GitHub.Issues.CreateComment.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :issues_create_comment
end
