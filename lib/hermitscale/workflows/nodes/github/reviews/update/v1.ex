defmodule Hermitscale.Workflows.Nodes.GitHub.Reviews.Update.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :reviews_update
end
