defmodule Hermitscale.Workflows.Nodes.GitHub.Repositories.ListReferrers.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :repositories_list_referrers
end
