defmodule Hermitscale.Agents.ReconcileWorkerTest do
  use Hermitscale.DataCase, async: false
  use Oban.Testing, repo: Hermitscale.Repo
  import Hermitscale.AgentsFixtures
  alias Hermitscale.{Agents, Auth, AuthTest.Provider}
  alias Hermitscale.Agents.ReconcileWorker

  setup do
    original = Application.fetch_env!(:hermitscale, Auth)
    Application.put_env(:hermitscale, Auth, provider: Provider)
    on_exit(fn -> Application.put_env(:hermitscale, Auth, original) end)
    start_supervised!({Provider, %{}})
    {:ok, authentication} = Auth.sign_in("team-code")
    scope = authentication.current_scope
    session = agent_session_fixture(scope)
    %{scope: scope, session: session}
  end

  test "Jido coordinates committed interruption and retries do not duplicate work", %{
    scope: scope,
    session: session
  } do
    turn = agent_turn_fixture(scope, session)
    assert {:ok, %{status: "interrupted"}} = perform_job(ReconcileWorker, %{turn_id: turn.id})
    assert is_nil(Jido.whereis(Hermitscale.AgentRuntime, "session:" <> session.id))
    assert {:ok, %{status: :interrupted}} = perform_job(ReconcileWorker, %{turn_id: turn.id})

    assert [%{type: "turn.queued"}, %{type: "turn.interrupted"}] =
             Agents.list_events(scope, session.id)
  end

  test "revocation after admission prevents dispatch and preserves the reason", %{
    scope: scope,
    session: session
  } do
    turn = agent_turn_fixture(scope, session)
    :ok = Provider.remove_membership("membership:owner")

    assert {:cancel, :execution_actor_ineligible} =
             perform_job(ReconcileWorker, %{turn_id: turn.id})

    assert {:ok, %{status: :interrupted, error: %{"reason" => "execution_actor_ineligible"}}} =
             Agents.get_turn(scope, turn.id)
  end

  test "a later queued turn waits for the earlier occurrence", %{scope: scope, session: session} do
    _first = agent_turn_fixture(scope, session)
    second = agent_turn_fixture(scope, session)
    assert {:snooze, 10} = perform_job(ReconcileWorker, %{turn_id: second.id})
    assert {:ok, %{status: :queued}} = Agents.get_turn(scope, second.id)
  end

  test "admission rechecks current membership even when browser scope is stale", %{
    scope: scope,
    session: session
  } do
    :ok = Provider.remove_membership("membership:owner")

    assert {:error, :execution_actor_ineligible} =
             Agents.submit_turn(scope, session.id, %{
               instructions: "Revoked",
               operation_key: Ecto.UUID.generate()
             })

    assert [] == Agents.list_turns(scope, session.id)
  end

  test "provider unavailability retries but final dispatch attempt durably settles undispatched work",
       %{scope: scope, session: session} do
    turn = agent_turn_fixture(scope, session)
    Provider.put_response(:list_memberships, {:error, :unavailable})
    assert {:error, :unavailable} = perform_job(ReconcileWorker, %{turn_id: turn.id})

    assert {:cancel, :unavailable} =
             perform_job(ReconcileWorker, %{turn_id: turn.id}, attempt: 5, max_attempts: 5)

    assert {:ok, %{status: :interrupted, error: %{"reason" => "authority_unavailable"}}} =
             Agents.get_turn(scope, turn.id)
  end
end
