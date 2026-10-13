defmodule Hermitscale.AgentsFixtures do
  @moduledoc false
  alias Hermitscale.{Agents, AccountsFixtures}

  def agent_scope_fixture do
    scope = AccountsFixtures.organization_scope_fixture()

    %{
      scope
      | membership: %{
          scope.membership
          | permissions: ["agents:read", "agents:run", "workspaces:read", "workspaces:write"]
        }
    }
  end

  def agent_session_fixture(scope, attrs \\ %{}) do
    {:ok, session} =
      Agents.start_session(
        scope,
        Map.merge(
          %{
            title: "Investigate validation",
            repository: "acme/widget",
            base_sha: String.duplicate("a", 40)
          },
          attrs
        )
      )

    session
  end

  def agent_turn_fixture(scope, session, attrs \\ %{}) do
    {:ok, turn} =
      Agents.submit_turn(
        scope,
        session.id,
        Map.merge(
          %{
            instructions: "Investigate the defect and record evidence.",
            operation_key: Ecto.UUID.generate()
          },
          attrs
        )
      )

    turn
  end
end
