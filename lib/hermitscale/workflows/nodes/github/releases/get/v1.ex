defmodule Hermitscale.Workflows.Nodes.GitHub.Releases.Get.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :releases_get
end
