defmodule Hermitscale.Workflows.Nodes.GitHub.Repositories.ListPopularPaths.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :repositories_list_popular_paths
end
