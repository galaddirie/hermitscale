defmodule HermitscaleWeb.AgentFixtures do
  @moduledoc false

  def conversation_fixture(scope, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{title: "Build a useful app"})
    {:ok, session} = Hermitscale.Agents.start_session(scope, attrs)
    session
  end

  def turn_fixture(scope, session, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        instructions: "Inspect the workspace",
        operation_key: Ecto.UUID.generate(),
        budget_cents: 500,
        timeout_seconds: 1800
      })

    {:ok, turn} = Hermitscale.Agents.submit_turn(scope, session.id, attrs)
    turn
  end
end
