defmodule Hermitscale.Workflows.Nodes.GitHub.Organizations.GetMembers.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :organizations_get_members
end
