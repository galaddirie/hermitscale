defmodule Hermitscale.Workflows.Nodes.GitHub.Files.Get.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :files_get
end
