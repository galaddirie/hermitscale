defmodule Hermitscale.Workflows.Nodes.GitHub.Releases.List.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :releases_list
end
