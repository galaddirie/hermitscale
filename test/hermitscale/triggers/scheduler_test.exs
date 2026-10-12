defmodule Hermitscale.Triggers.SchedulerTest do
  use Hermitscale.DataCase, async: false
  use Oban.Testing, repo: Hermitscale.Repo

  import Ecto.Query
  import Hermitscale.AccountsFixtures
  import Hermitscale.TriggersFixtures

  alias Hermitscale.Triggers.{FireWorker, Firing, Scheduler, Trigger}
  alias Hermitscale.Workflows.Run

  setup do
    %{scope: user_scope_fixture()}
  end

  defp start_scheduler! do
    start_supervised!({Scheduler, name: :test_scheduler, tick_ms: :timer.hours(1)})
  end

  defp make_due!(trigger) do
    past = DateTime.add(DateTime.utc_now(:second), -120)

    Trigger
    |> where([t], t.id == ^trigger.id)
    |> Repo.update_all(set: [next_fire_at: past])
  end

  test "a tick enqueues one unique job per due trigger and advances next_fire_at", %{
    scope: scope
  } do
    {_graph, trigger} =
      activate_trigger_graph!(scope, schedule_trigger_node(%{"cron" => "* * * * *"}))

    make_due!(trigger)
    scheduler = start_scheduler!()

    assert Scheduler.tick(scheduler) == 1
    assert_enqueued(worker: FireWorker, args: %{trigger_id: trigger.id})

    advanced = Repo.get!(Trigger, trigger.id)
    assert DateTime.after?(advanced.next_fire_at, DateTime.utc_now())

    # The trigger is no longer due, so the next tick is a no-op.
    assert Scheduler.tick(scheduler) == 0
  end

  test "triggers scheduled in the future are not fired", %{scope: scope} do
    {_graph, _trigger} =
      activate_trigger_graph!(scope, schedule_trigger_node(%{"cron" => "* * * * *"}))

    scheduler = start_scheduler!()

    assert Scheduler.tick(scheduler) == 0
    refute_enqueued(worker: FireWorker)
  end

  test "FireWorker dispatches exactly one run per occurrence, across retries", %{scope: scope} do
    {_graph, trigger} =
      activate_trigger_graph!(scope, schedule_trigger_node(%{"cron" => "* * * * *"}))

    scheduled_for = DateTime.to_iso8601(trigger.next_fire_at)
    args = %{"trigger_id" => trigger.id, "scheduled_for" => scheduled_for}

    assert {:ok, %Run{}} = perform_job(FireWorker, args)
    assert {:ok, :deduped} = perform_job(FireWorker, args)

    assert Repo.aggregate(Run, :count) == 1
    assert [firing] = Repo.all(Firing)
    assert firing.idempotency_key == "schedule:#{trigger.id}:#{scheduled_for}"

    run = Repo.one!(Run)
    envelope = run.input["value"]
    assert envelope["data"]["scheduled_at"] == scheduled_for
    assert envelope["trigger"]["mode"] == "schedule"
  end

  test "FireWorker is a no-op for deleted or disabled triggers", %{scope: scope} do
    {_graph, trigger} =
      activate_trigger_graph!(scope, schedule_trigger_node(%{"cron" => "* * * * *"}))

    {:ok, _disabled} = Hermitscale.Triggers.disable_trigger(scope, trigger)

    args = %{
      "trigger_id" => trigger.id,
      "scheduled_for" => DateTime.to_iso8601(trigger.next_fire_at)
    }

    assert {:cancel, :disabled} = perform_job(FireWorker, args)

    assert {:cancel, :deleted} =
             perform_job(FireWorker, %{args | "trigger_id" => Ecto.UUID.generate()})

    assert Repo.aggregate(Run, :count) == 0
  end

  test "FireWorker cancels malformed persisted job arguments" do
    assert {:cancel, :invalid_args} = perform_job(FireWorker, %{})

    assert {:cancel, :invalid_args} =
             perform_job(FireWorker, %{trigger_id: 123, scheduled_for: "invalid"})

    assert {:cancel, :invalid_scheduled_for} =
             perform_job(FireWorker, %{trigger_id: Ecto.UUID.generate(), scheduled_for: "invalid"})
  end

  test "FireWorker retries authority outages and cancels permanently ineligible actors", %{
    scope: scope
  } do
    alias Hermitscale.WorkOSTest.Client
    start_supervised!({Client, %{}})
    {_graph, trigger} = activate_trigger_graph!(scope, schedule_trigger_node())
    args = %{trigger_id: trigger.id, scheduled_for: DateTime.to_iso8601(trigger.next_fire_at)}

    Client.put_response(:get_role, {:error, :unavailable})
    assert {:error, :unavailable} = perform_job(FireWorker, args)
    assert Repo.get!(Trigger, trigger.id).status == :enabled

    Client.put_response(:get_role, {:ok, %{"slug" => "admin", "permissions" => []}})
    assert {:cancel, :execution_actor_ineligible} = perform_job(FireWorker, args)
    assert Repo.get!(Trigger, trigger.id).status == :errored
  end

  test "FireWorker retains unresolved occurrences for a later retry", %{scope: scope} do
    {_graph, trigger} = activate_trigger_graph!(scope, schedule_trigger_node())
    scheduled_for = DateTime.to_iso8601(trigger.next_fire_at)
    unresolved_firing_fixture(trigger, "schedule:#{trigger.id}:#{scheduled_for}")

    assert {:error, :firing_in_progress} =
             perform_job(FireWorker, %{trigger_id: trigger.id, scheduled_for: scheduled_for})
  end

  test "FireWorker retries malformed dependency responses without revoking the actor", %{
    scope: scope
  } do
    alias Hermitscale.WorkOSTest.Client
    start_supervised!({Client, %{}})
    {_graph, trigger} = activate_trigger_graph!(scope, schedule_trigger_node())
    Client.put_response(:get_role, {:error, :invalid_response})

    assert {:error, :invalid_response} =
             perform_job(FireWorker, %{
               trigger_id: trigger.id,
               scheduled_for: DateTime.to_iso8601(trigger.next_fire_at)
             })

    assert Repo.get!(Trigger, trigger.id).status == :enabled
  end
end
