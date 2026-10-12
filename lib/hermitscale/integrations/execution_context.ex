defmodule Hermitscale.Integrations.ExecutionContext do
  @moduledoc "Trusted, non-secret organization and acting-member identity."
  @enforce_keys [:organization_id, :actor_user_id]
  defstruct [:organization_id, :actor_user_id, required_permissions: ["workflows:run"]]
end
