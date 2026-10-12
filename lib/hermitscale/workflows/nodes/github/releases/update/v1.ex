defmodule Hermitscale.Workflows.Nodes.GitHub.Releases.Update.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :releases_update
end
