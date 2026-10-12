defmodule Hermitscale.Workflows.Nodes.GitHub.Users.Invite.V1 do
  @moduledoc false
  use Hermitscale.Integrations.Action,
    operations: Hermitscale.Integrations.GitHub.Operations,
    operation: :users_invite
end
