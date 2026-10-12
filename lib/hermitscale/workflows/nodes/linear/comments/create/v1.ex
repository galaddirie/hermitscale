defmodule Hermitscale.Workflows.Nodes.Linear.Comments.Create.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.Linear.Operations,
    operation: :comments_create
end
