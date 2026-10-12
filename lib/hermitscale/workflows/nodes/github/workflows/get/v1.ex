defmodule Hermitscale.Workflows.Nodes.GitHub.Workflows.Get.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :workflows_get
end
