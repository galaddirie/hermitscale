defmodule Hermitscale.Workflows.Nodes.GitHub.Files.List.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :files_list
end
