defmodule Hermitscale.Triggers.RuntimeTest do
  use Hermitscale.DataCase, async: false

  import Hermitscale.AccountsFixtures
  import Hermitscale.TriggersFixtures

  alias Hermitscale.Triggers
  alias Hermitscale.Triggers.{Firing, Reconciler, Trigger}
  alias Hermitscale.Triggers.Runtime.{Poller, StreamSource}
  alias Hermitscale.Workflows.Run

  setup do
    %{scope: user_scope_fixture()}
  end

  defp stop_source!(pid) do
    ref = Process.monitor(pid)
    :ok = GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    assert Repo.aggregate(from(run in Run, where: run.status == :running), :count) == 0
  end

  defp poll(pid) do
    send(pid, :poll)
    :sys.get_state(pid)
  end

  describe "Poller" do
    test "polls, dispatches runs, and persists the cursor", %{scope: scope} do
      {_graph, trigger} =
        activate_trigger_graph!(scope, polling_trigger_node(%{"poll_interval_ms" => 3_600_000}))

      poller =
        start_supervised!(
          {Poller, trigger_id: trigger.id, initial_poll_delay_ms: :timer.hours(1)}
        )

      poll(poller)
      poll(poller)
      assert Repo.aggregate(Run, :count) == 2
      assert Repo.get!(Trigger, trigger.id).cursor == %{"count" => 2}

      firing = Repo.one!(Ecto.Query.from(f in Firing, limit: 1, order_by: f.id))
      assert firing.idempotency_key == "tick-1"

      run = Repo.one!(Ecto.Query.from(r in Run, limit: 1, order_by: r.inserted_at))
      assert run.input["value"]["trigger"]["mode"] == "polling"

      stop_source!(poller)
    end

    test "resolves credentials freshly for each poll and passes them in ctx", %{scope: scope} do
      graph =
        create_graph!(
          scope,
          trigger_graph(
            polling_trigger_node(%{
              "poll_interval_ms" => 3_600_000,
              "behavior" => "emit_credentials"
            }),
            %{}
          )
        )

      {:ok, %{triggers: [trigger]}} = Triggers.activate_graph(scope, graph)

      poller =
        start_supervised!(
          {Poller, trigger_id: trigger.id, initial_poll_delay_ms: :timer.hours(1)}
        )

      poll(poller)
      assert Repo.aggregate(Run, :count) == 1

      run = Repo.one!(Ecto.Query.from(r in Run, limit: 1, order_by: r.inserted_at))
      assert run.input["value"]["data"]["account_id"] == "data_test"

      stop_source!(poller)
    end

    test "a persistently failing trigger is flagged errored and the poller stops", %{
      scope: scope
    } do
      {_graph, trigger} =
        activate_trigger_graph!(
          scope,
          polling_trigger_node(%{"poll_interval_ms" => 3_600_000, "behavior" => "fail"})
        )

      pid =
        start_supervised!(
          {Poller,
           trigger_id: trigger.id, failure_threshold: 1, initial_poll_delay_ms: :timer.hours(1)}
        )

      ref = Process.monitor(pid)
      send(pid, :poll)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 3_000
      assert Repo.get!(Trigger, trigger.id).status == :errored
      assert Repo.aggregate(Run, :count) == 0
    end
  end

  describe "StreamSource" do
    test "connects and fires a run per emitted event", %{scope: scope} do
      {_graph, trigger} = activate_trigger_graph!(scope, stream_trigger_node())

      pid = start_supervised!({StreamSource, trigger_id: trigger.id})

      send(pid, {:emit, %{"frame" => 1}})
      send(pid, {:emit, %{"frame" => 2}})

      _ = :sys.get_state(pid)
      assert Repo.aggregate(Run, :count) == 2

      inputs =
        Run
        |> Repo.all()
        |> Enum.map(& &1.input["value"]["data"])
        |> Enum.sort_by(& &1["frame"])

      assert inputs == [%{"frame" => 1}, %{"frame" => 2}]

      stop_source!(pid)
    end

    test "a connection that cannot be established flags the trigger errored", %{scope: scope} do
      {_graph, trigger} =
        activate_trigger_graph!(scope, stream_trigger_node(%{"behavior" => "refuse"}))

      pid = start_supervised!({StreamSource, trigger_id: trigger.id, failure_threshold: 2})
      assert %{connected?: false, failures: 1} = :sys.get_state(pid)
      ref = Process.monitor(pid)
      send(pid, :connect)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 3_000
      assert Repo.get!(Trigger, trigger.id).status == :errored
    end
  end

  describe "Reconciler" do
    setup do
      start_supervised!({Registry, keys: :unique, name: :test_trigger_registry})

      start_supervised!(
        {DynamicSupervisor, name: :test_source_supervisor, strategy: :one_for_one}
      )

      reconciler =
        start_supervised!(
          {Reconciler,
           name: :test_reconciler,
           registry: :test_trigger_registry,
           supervisor: :test_source_supervisor,
           sweep_ms: :timer.hours(1)}
        )

      %{reconciler: reconciler}
    end

    defp registered(trigger), do: Registry.lookup(:test_trigger_registry, trigger.id)

    test "starts sources for enabled triggers and stops them when disabled",
         %{reconciler: reconciler, scope: scope} do
      {_graph, trigger} =
        activate_trigger_graph!(
          scope,
          polling_trigger_node(%{"poll_interval_ms" => 3_600_000})
        )

      Reconciler.sync(reconciler)
      assert [{pid, _fingerprint}] = registered(trigger)
      _ = :sys.get_state(pid)

      {:ok, _disabled} = Triggers.disable_trigger(scope, trigger)

      Reconciler.sync(reconciler)
      assert registered(trigger) == []
    end

    test "restarts a source whose trigger config changed", %{
      reconciler: reconciler,
      scope: scope
    } do
      {_graph, trigger} =
        activate_trigger_graph!(
          scope,
          polling_trigger_node(%{"poll_interval_ms" => 3_600_000})
        )

      Reconciler.sync(reconciler)
      assert [{original_pid, _fingerprint}] = registered(trigger)
      _ = :sys.get_state(original_pid)

      Trigger
      |> Ecto.Query.where(id: ^trigger.id)
      |> Repo.update_all(set: [config: %{"poll_interval_ms" => 1_800_000}])

      Reconciler.sync(reconciler)
      assert [{pid, _fingerprint}] = registered(trigger)
      assert pid != original_pid
      _ = :sys.get_state(pid)
    end
  end
end
