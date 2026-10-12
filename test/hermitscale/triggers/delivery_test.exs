defmodule Hermitscale.Triggers.DeliveryTest do
  use Hermitscale.DataCase, async: false

  import ExUnit.CaptureLog
  import Hermitscale.AccountsFixtures
  import Hermitscale.TriggersFixtures

  alias Hermitscale.Triggers
  alias Hermitscale.Triggers.{Firing, Trigger}
  alias Hermitscale.Triggers.Runtime.{Poller, StreamSource}
  alias Hermitscale.Workflows.Run
  alias Hermitscale.WorkOSTest.Client

  setup do
    %{scope: user_scope_fixture()}
  end

  defp start_poller!(trigger, opts \\ []) do
    {Poller, [trigger_id: trigger.id, initial_poll_delay_ms: :timer.hours(1)] ++ opts}
    |> Supervisor.child_spec(id: trigger.id)
    |> start_supervised!()
  end

  defp poll(pid) do
    send(pid, :poll)
    :sys.get_state(pid)
  end

  describe "poll batch delivery" do
    test "expected dependency outages back off while preserving a usable source", %{scope: scope} do
      start_supervised!({Client, %{}})

      {_graph, trigger} =
        activate_trigger_graph!(scope, polling_trigger_node(%{"behavior" => "quiet"}))

      pid = start_poller!(trigger)

      for {reason, failures} <-
            Enum.with_index([:unavailable, :rate_limited, :invalid_response], 1) do
        Client.put_response(:get_role, {:error, reason})
        assert %{failures: ^failures} = poll(pid)
        assert Repo.get!(Trigger, trigger.id).status == :enabled
        assert Repo.get!(Trigger, trigger.id).cursor == %{"count" => 0}
      end

      Client.put_response(
        :get_role,
        {:ok, %{"slug" => "admin", "permissions" => role_permissions_fixture("admin")}}
      )

      assert %{failures: 0} = poll(pid)
      assert Repo.aggregate(Run, :count) == 0
    end

    test "a failed dispatch retains its cursor until the same event succeeds", %{scope: scope} do
      {graph, trigger} = activate_trigger_graph!(scope, polling_trigger_node())
      pid = start_poller!(trigger)

      graph
      |> change(definition: %{graph.definition | "nodes" => [hd(graph.definition["nodes"])]})
      |> Repo.update!()

      poll(pid)
      assert Repo.get!(Trigger, trigger.id).cursor == %{"count" => 0}
      assert [%Firing{outcome: :failed}] = Repo.all(Firing)

      Repo.get!(Hermitscale.Workflows.Graph, graph.id)
      |> change(definition: graph.definition)
      |> Repo.update!()

      poll(pid)
      assert Repo.get!(Trigger, trigger.id).cursor == %{"count" => 1}
      assert [%Firing{outcome: :dispatched, run_id: run_id}] = Repo.all(Firing)
      assert is_binary(run_id)
      assert Repo.aggregate(Run, :count) == 1
    end

    test "a partial batch replays successful keys and retains failed events", %{scope: scope} do
      start_supervised!({Client, %{}})

      {_graph, trigger} =
        activate_trigger_graph!(scope, polling_trigger_node(%{"behavior" => "batch"}))

      pid = start_poller!(trigger)

      Client.put_response(:get_role, fn slug ->
        if Repo.aggregate(Run, :count) == 1,
          do: {:error, :unavailable},
          else: {:ok, %{"slug" => slug, "permissions" => role_permissions_fixture("admin")}}
      end)

      poll(pid)
      assert Repo.aggregate(Run, :count) == 1
      assert Repo.get!(Trigger, trigger.id).cursor == %{"count" => 0}

      Client.put_response(
        :get_role,
        {:ok, %{"slug" => "admin", "permissions" => role_permissions_fixture("admin")}}
      )

      poll(pid)
      assert Repo.aggregate(Run, :count) == 2
      assert Repo.aggregate(Firing, :count) == 2
      assert Repo.get!(Trigger, trigger.id).cursor == %{"count" => 2}
    end

    test "intentional admission rejection consumes the event", %{scope: scope} do
      {graph, trigger} =
        activate_trigger_graph!(scope, polling_trigger_node(%{"max_concurrent_runs" => 1}))

      {:ok, _run} =
        Hermitscale.Workflows.create_run(scope, graph, %{
          status: :running,
          id: Ecto.UUID.generate()
        })

      pid = start_poller!(trigger)

      poll(pid)
      assert Repo.get!(Trigger, trigger.id).cursor == %{"count" => 1}
      assert [%Firing{outcome: :rejected}] = Repo.all(Firing)
    end

    test "disabled and deleted sources stop normally without becoming errored", %{scope: scope} do
      {_graph, trigger} = activate_trigger_graph!(scope, polling_trigger_node())
      pid = start_poller!(trigger)
      ref = Process.monitor(pid)
      {:ok, _trigger} = Triggers.disable_trigger(scope, trigger)
      send(pid, :poll)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert Repo.get!(Trigger, trigger.id).status == :disabled

      {_graph, trigger} =
        activate_trigger_graph!(scope, polling_trigger_node(), %{"id" => "wf_deleted"})

      pid = start_poller!(trigger)
      ref = Process.monitor(pid)
      Repo.delete!(trigger)
      send(pid, :poll)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    test "callback exceptions are logged with stacktraces and quarantined immediately", %{
      scope: scope
    } do
      {_graph, trigger} =
        activate_trigger_graph!(scope, polling_trigger_node(%{"behavior" => "crash"}))

      pid = start_poller!(trigger)
      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          send(pid, :poll)
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
        end)

      assert log =~ "RuntimeError"
      assert log =~ "CounterPollProbe.V1.poll"
      refute log =~ "poll callback bug"
      assert Repo.get!(Trigger, trigger.id).status == :errored
    end

    test "an invalid callback return is quarantined without repeated retries", %{scope: scope} do
      {_graph, trigger} =
        activate_trigger_graph!(scope, polling_trigger_node(%{"behavior" => "invalid"}))

      pid = start_poller!(trigger)
      ref = Process.monitor(pid)
      send(pid, :poll)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert Repo.get!(Trigger, trigger.id).status == :errored
    end
  end

  describe "stream callback isolation" do
    test "successful reconnects do not erase repeated dispatch failures", %{scope: scope} do
      {graph, trigger} = activate_trigger_graph!(scope, stream_trigger_node())
      pid = start_supervised!({StreamSource, trigger_id: trigger.id, failure_threshold: 2})
      _ = :sys.get_state(pid)

      graph
      |> change(definition: %{graph.definition | "nodes" => [hd(graph.definition["nodes"])]})
      |> Repo.update!()

      send(pid, {:emit, %{"frame" => 1}})
      assert %{connected?: false, failures: 1} = :sys.get_state(pid)
      send(pid, :connect)
      assert %{connected?: true, failures: 1} = :sys.get_state(pid)

      ref = Process.monitor(pid)
      send(pid, {:emit, %{"frame" => 2}})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert Repo.get!(Trigger, trigger.id).status == :errored
      assert Repo.aggregate(Run, :count) == 0
    end

    test "cleanup callback bugs remain visible and quarantine the source", %{scope: scope} do
      {_graph, trigger} =
        activate_trigger_graph!(scope, stream_trigger_node(%{"behavior" => "terminate_crash"}))

      pid = start_supervised!({StreamSource, trigger_id: trigger.id})
      _ = :sys.get_state(pid)
      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          send(pid, :please_reconnect)
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
        end)

      assert log =~ "RuntimeError"
      assert log =~ "RelayStreamProbe.V1.terminate_stream"
      refute log =~ "stream cleanup bug"
      errored = Repo.get!(Trigger, trigger.id)
      assert errored.status == :errored
      assert errored.error["action"] == "repair_source"
    end

    test "a stream handler bug is logged and stops its source normally", %{scope: scope} do
      {_graph, trigger} = activate_trigger_graph!(scope, stream_trigger_node())
      pid = start_supervised!({StreamSource, trigger_id: trigger.id})
      _ = :sys.get_state(pid)
      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          send(pid, :crash)
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
        end)

      assert log =~ "RuntimeError"
      assert log =~ "RelayStreamProbe.V1.handle_event"
      refute log =~ "stream handler bug"
      assert Repo.get!(Trigger, trigger.id).status == :errored
    end
  end
end
