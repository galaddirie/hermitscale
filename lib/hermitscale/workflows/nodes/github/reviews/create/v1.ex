defmodule Hermitscale.Workflows.Nodes.GitHub.Reviews.Create.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :reviews_create
end
