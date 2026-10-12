defmodule Hermitscale.Workflows.Nodes.GitHub.Issues.Lock.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :issues_lock
end
