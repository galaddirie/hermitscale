defmodule Hermitscale.Workflows.Nodes.GitHub.Releases.Delete.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :releases_delete
end
