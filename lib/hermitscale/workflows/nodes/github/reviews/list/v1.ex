defmodule Hermitscale.Workflows.Nodes.GitHub.Reviews.List.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :reviews_list
end
