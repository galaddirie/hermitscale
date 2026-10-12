defmodule Hermitscale.Workflows.Nodes.GitHub.Reviews.Get.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :reviews_get
end
