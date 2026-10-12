defmodule Hermitscale.Triggers.DispatcherTest do
  use Hermitscale.DataCase, async: false

  import Ecto.Query
  import Hermitscale.AccountsFixtures
  import Hermitscale.TriggersFixtures

  alias Hermitscale.Triggers
  alias Hermitscale.Triggers.{Dispatcher, Firing}
  alias Hermitscale.Workflows.Run

  setup do
    %{scope: user_scope_fixture()}
  end

  test "manual dispatch requires caller scope and never uses the activation actor", %{
    scope: scope
  } do
    {_graph, trigger} = activate_trigger_graph!(scope, manual_trigger_node())
    assert {:error, :caller_scope_required} = Dispatcher.fire(trigger, %{})
    collaborator = organization_scope_fixture(user_fixture(), scope.organization)

    assert {:ok, run} =
             Triggers.fire_manual(collaborator, trigger, %{}, run_opts: [executor: :inline])

    assert run.initiated_by_user_id == collaborator.user.id
    assert run.execution_actor_user_id == collaborator.user.id
    assert run.execution_actor_user_id != trigger.execution_actor_user_id
  end

  test "unattended modes preserve the activation actor and recheck current authority", %{
    scope: scope
  } do
    alias Hermitscale.WorkOSTest.Client
    start_supervised!({Client, %{}})

    for node <- [
          webhook_trigger_node(),
          schedule_trigger_node(),
          polling_trigger_node(),
          stream_trigger_node()
        ] do
      {_graph, trigger} = activate_trigger_graph!(scope, node)
      assert {:ok, run} = Dispatcher.fire(trigger, %{}, run_opts: [executor: :inline])
      assert run.execution_actor_user_id == scope.user.id
      assert run.initiated_by_user_id == nil
      assert run.trigger_id == trigger.id
    end

    {_graph, trigger} =
      activate_trigger_graph!(scope, webhook_trigger_node(%{"max_concurrent_runs" => 3}), %{
        "id" => "wf_actor_removed"
      })

    Client.put_response(:get_role, {:ok, %{"permissions" => ["workflows:run"]}})
    assert {:error, :execution_actor_ineligible} = Dispatcher.fire(trigger, %{})
    errored = Triggers.get_trigger!(trigger.id)
    assert errored.status == :errored
    assert errored.error["action"] == "reassign_actor"
  end

  test "fires a run and records a dispatched firing", %{scope: scope} do
    {_graph, trigger} = activate_trigger_graph!(scope, manual_trigger_node())

    assert {:ok, %Run{} = run} = Dispatcher.fire(trigger, %{"n" => 1}, scope: scope)

    assert [firing] = Repo.all(Firing)
    assert firing.outcome == :dispatched
    assert firing.run_id == run.id
  end

  test "dedupes on idempotency key", %{scope: scope} do
    {_graph, trigger} = activate_trigger_graph!(scope, manual_trigger_node())

    assert {:ok, %Run{}} =
             Dispatcher.fire(trigger, %{"n" => 1}, idempotency_key: "event-1", scope: scope)

    assert {:ok, :deduped} =
             Dispatcher.fire(trigger, %{"n" => 1}, idempotency_key: "event-1", scope: scope)

    assert Repo.aggregate(Firing, :count) == 1
    assert Repo.aggregate(Run, :count) == 1
  end

  test "a failed firing can be retried under the same key", %{scope: scope} do
    {graph, trigger} = activate_trigger_graph!(scope, manual_trigger_node())

    # Corrupt the stored definition under the changeset's radar so start_run
    # fails at compile time.
    broken = Map.put(graph.definition, "nodes", [])

    graph
    |> Ecto.Changeset.change(definition: broken)
    |> Repo.update!()

    assert {:error, {:start_run, _reason}} =
             Dispatcher.fire(trigger, %{"n" => 1}, idempotency_key: "event-1", scope: scope)

    assert [%Firing{outcome: :failed}] = Repo.all(Firing)

    # Retry claims the failed firing instead of deduping against it.
    assert {:error, {:start_run, _reason}} =
             Dispatcher.fire(trigger, %{"n" => 1}, idempotency_key: "event-1", scope: scope)

    assert Repo.aggregate(Firing, :count) == 1
  end

  test "an unresolved firing remains in progress rather than claiming successful deduplication",
       %{scope: scope} do
    {_graph, trigger} = activate_trigger_graph!(scope, manual_trigger_node())
    firing = unresolved_firing_fixture(trigger, "interrupted")

    assert {:error, :firing_in_progress} =
             Dispatcher.fire(trigger, %{}, scope: scope, idempotency_key: "interrupted")

    assert Repo.get!(Firing, firing.id).run_id == nil
    assert Repo.aggregate(Run, :count) == 0
  end

  test "a trigger deleted after loading cannot fire", %{scope: scope} do
    {_graph, trigger} = activate_trigger_graph!(scope, manual_trigger_node())
    Repo.delete!(trigger)
    assert {:error, :disabled} = Dispatcher.fire(trigger, %{}, scope: scope)
  end

  test "execution_scope reloads persisted actor and status rather than trusting a supplied snapshot",
       %{scope: scope} do
    {_graph, trigger} = activate_trigger_graph!(scope, webhook_trigger_node())
    forged = %{trigger | execution_actor_user_id: "user_forged"}
    assert {:ok, actor_scope, _context} = Triggers.execution_scope(forged)
    assert actor_scope.user.id == trigger.execution_actor_user_id

    {:ok, _disabled} = Triggers.disable_trigger(scope, trigger)
    assert {:error, :disabled} = Triggers.execution_scope(trigger)
  end

  test "rejects firings over the max_concurrent_runs limit", %{scope: scope} do
    {graph, trigger} =
      activate_trigger_graph!(scope, manual_trigger_node(%{"max_concurrent_runs" => 1}))

    {:ok, _running} =
      Hermitscale.Workflows.create_run(scope, graph, %{
        status: :running,
        id: Ecto.UUID.generate()
      })

    assert {:error, :rejected} = Dispatcher.fire(trigger, %{"n" => 1}, scope: scope)

    assert [firing] = Repo.all(from(f in Firing, where: f.outcome == :rejected))
    assert firing.error["reason"] == "max_concurrent_runs"
    assert Repo.aggregate(from(r in Run, where: r.status == :running), :count) == 1
  end

  test "refuses to fire disabled and errored triggers", %{scope: scope} do
    {_graph, trigger} = activate_trigger_graph!(scope, manual_trigger_node())

    {:ok, disabled} = Triggers.disable_trigger(scope, trigger)
    assert {:error, :disabled} = Dispatcher.fire(disabled, %{})

    {:ok, errored} = Triggers.mark_errored(disabled, :boom)
    assert {:error, :disabled} = Dispatcher.fire(errored, %{})

    assert Repo.aggregate(Firing, :count) == 0
  end
end
