defmodule Hermitscale.Workflows.Nodes.GitHub.Files.Create.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :files_create
end
