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

  defp wait_until(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(25)
        do_wait_until(fun, deadline)
    end
  end

  defp stop_source_and_wait_for_runs!(pid) do
    ref = Process.monitor(pid)
    :ok = GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    wait_until(fn ->
      Run
      |> Ecto.Query.where([run], run.status == :running)
      |> Repo.aggregate(:count) == 0
    end)
  end

  describe "Poller" do
    test "polls, dispatches runs, and persists the cursor", %{scope: scope} do
      {_graph, trigger} =
        activate_trigger_graph!(scope, polling_trigger_node(%{"poll_interval_ms" => 25}))

      poller = start_supervised!({Poller, trigger_id: trigger.id})

      wait_until(fn -> Repo.aggregate(Run, :count) >= 2 end)
      wait_until(fn -> (Repo.get!(Trigger, trigger.id).cursor["count"] || 0) >= 2 end)

      firing = Repo.one!(Ecto.Query.from(f in Firing, limit: 1, order_by: f.id))
      assert firing.idempotency_key == "tick-1"

      run = Repo.one!(Ecto.Query.from(r in Run, limit: 1, order_by: r.inserted_at))
      assert run.input["value"]["trigger"]["mode"] == "polling"

      stop_source_and_wait_for_runs!(poller)
    end

    test "resolves credentials freshly for each poll and passes them in ctx", %{scope: scope} do
      graph =
        create_graph!(
          scope,
          trigger_graph(
            polling_trigger_node(%{
              "poll_interval_ms" => 25,
              "behavior" => "emit_credentials"
            }),
            %{
              "credentials" => %{
                "providers" => %{
                  "test.credentials" => %{
                    "provider" => "test.credentials",
                    "credential_id" => "cred_42"
                  }
                }
              }
            }
          )
        )

      {:ok, %{triggers: [trigger]}} = Triggers.activate_graph(scope, graph)
      poller = start_supervised!({Poller, trigger_id: trigger.id})

      wait_until(fn -> Repo.aggregate(Run, :count) >= 1 end)

      run = Repo.one!(Ecto.Query.from(r in Run, limit: 1, order_by: r.inserted_at))
      assert run.input["value"]["data"]["access_token"] == "token:cred_42"

      stop_source_and_wait_for_runs!(poller)
    end

    test "a persistently failing trigger is flagged errored and the poller stops", %{
      scope: scope
    } do
      {_graph, trigger} =
        activate_trigger_graph!(
          scope,
          polling_trigger_node(%{"poll_interval_ms" => 25, "behavior" => "fail"})
        )

      pid = start_supervised!({Poller, trigger_id: trigger.id, failure_threshold: 1})
      ref = Process.monitor(pid)

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

      wait_until(fn -> Repo.aggregate(Run, :count) == 2 end)

      inputs =
        Run
        |> Repo.all()
        |> Enum.map(& &1.input["value"]["data"])
        |> Enum.sort_by(& &1["frame"])

      assert inputs == [%{"frame" => 1}, %{"frame" => 2}]

      stop_source_and_wait_for_runs!(pid)
    end

    test "a connection that cannot be established flags the trigger errored", %{scope: scope} do
      {_graph, trigger} =
        activate_trigger_graph!(scope, stream_trigger_node(%{"behavior" => "refuse"}))

      pid = start_supervised!({StreamSource, trigger_id: trigger.id, failure_threshold: 1})
      ref = Process.monitor(pid)

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
      assert [{_pid, _fingerprint}] = registered(trigger)

      {:ok, _disabled} = Triggers.disable_trigger(scope, trigger)

      wait_until(fn ->
        Reconciler.sync(reconciler)
        registered(trigger) == []
      end)
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

      Trigger
      |> Ecto.Query.where(id: ^trigger.id)
      |> Repo.update_all(set: [config: %{"poll_interval_ms" => 1_800_000}])

      wait_until(fn ->
        Reconciler.sync(reconciler)

        case registered(trigger) do
          [{pid, _fingerprint}] -> pid != original_pid
          [] -> false
        end
      end)
    end
  end
end
