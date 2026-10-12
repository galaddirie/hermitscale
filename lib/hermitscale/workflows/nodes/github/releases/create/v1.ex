defmodule Hermitscale.Workflows.Nodes.GitHub.Releases.Create.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :releases_create
end
