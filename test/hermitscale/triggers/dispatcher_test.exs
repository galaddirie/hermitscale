defmodule Hermitscale.Triggers.DispatcherTest do
  use Hermitscale.DataCase, async: false

  import Ecto.Query
  import Hermitscale.TriggersFixtures

  alias Hermitscale.Triggers
  alias Hermitscale.Triggers.{Dispatcher, Firing}
  alias Hermitscale.Workflows.Run

  test "fires a run and records a dispatched firing" do
    {_graph, trigger} = activate_trigger_graph!(manual_trigger_node())

    assert {:ok, %Run{} = run} = Dispatcher.fire(trigger, %{"n" => 1})

    assert [firing] = Repo.all(Firing)
    assert firing.outcome == :dispatched
    assert firing.run_id == run.id
  end

  test "dedupes on idempotency key" do
    {_graph, trigger} = activate_trigger_graph!(manual_trigger_node())

    assert {:ok, %Run{}} = Dispatcher.fire(trigger, %{"n" => 1}, idempotency_key: "event-1")
    assert {:ok, :deduped} = Dispatcher.fire(trigger, %{"n" => 1}, idempotency_key: "event-1")

    assert Repo.aggregate(Firing, :count) == 1
    assert Repo.aggregate(Run, :count) == 1
  end

  test "a failed firing can be retried under the same key" do
    {graph, trigger} = activate_trigger_graph!(manual_trigger_node())

    # Corrupt the stored definition under the changeset's radar so start_run
    # fails at compile time.
    broken = Map.put(graph.definition, "nodes", [])

    graph
    |> Ecto.Changeset.change(definition: broken)
    |> Repo.update!()

    assert {:error, {:start_run, _reason}} =
             Dispatcher.fire(trigger, %{"n" => 1}, idempotency_key: "event-1")

    assert [%Firing{outcome: :failed}] = Repo.all(Firing)

    # Retry claims the failed firing instead of deduping against it.
    assert {:error, {:start_run, _reason}} =
             Dispatcher.fire(trigger, %{"n" => 1}, idempotency_key: "event-1")

    assert Repo.aggregate(Firing, :count) == 1
  end

  test "rejects firings over the max_concurrent_runs limit" do
    {graph, trigger} =
      activate_trigger_graph!(manual_trigger_node(%{"max_concurrent_runs" => 1}))

    {:ok, _running} =
      Hermitscale.Workflows.create_run(graph, %{status: :running, id: Ecto.UUID.generate()})

    assert {:error, :rejected} = Dispatcher.fire(trigger, %{"n" => 1})

    assert [firing] = Repo.all(from(f in Firing, where: f.outcome == :rejected))
    assert firing.error["reason"] == "max_concurrent_runs"
    assert Repo.aggregate(from(r in Run, where: r.status == :running), :count) == 1
  end

  test "refuses to fire disabled and errored triggers" do
    {_graph, trigger} = activate_trigger_graph!(manual_trigger_node())

    {:ok, disabled} = Triggers.disable_trigger(trigger)
    assert {:error, :disabled} = Dispatcher.fire(disabled, %{})

    {:ok, errored} = Triggers.mark_errored(disabled, :boom)
    assert {:error, :disabled} = Dispatcher.fire(errored, %{})

    assert Repo.aggregate(Firing, :count) == 0
  end
end
