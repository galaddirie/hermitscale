defmodule Hermitscale.Triggers.Reconciler do
  @moduledoc """
  Makes running source processes match the desired state in Postgres.

  Desired state is "every enabled polling/stream trigger has a source process".
  The reconciler diffs that against the registry and starts/stops children
  under the source supervisor. It syncs on boot, on every trigger-change
  broadcast, and on a slow periodic sweep that catches missed messages.

  A source whose trigger config changed while it was running (re-activation
  with edited params) is restarted: the registry value carries a config
  fingerprint, and a mismatch counts as an orphan plus a missing source.
  """

  use GenServer

  alias Hermitscale.Triggers
  alias Hermitscale.Triggers.Runtime.{Poller, StreamSource}
  alias Hermitscale.Triggers.Trigger

  @sweep_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Synchronously reconciles now. Used by tests; production flows rely on
  broadcasts and the sweep.
  """
  def sync(server \\ __MODULE__), do: GenServer.call(server, :sync)

  def fingerprint(%Trigger{} = trigger) do
    {trigger.type, trigger.version, trigger.config, trigger.execution_actor_user_id}
  end

  @impl true
  def init(opts) do
    state = %{
      registry: Keyword.get(opts, :registry, Hermitscale.Triggers.Registry),
      supervisor: Keyword.get(opts, :supervisor, Hermitscale.Triggers.SourceSupervisor),
      sweep_ms: Keyword.get(opts, :sweep_ms, @sweep_ms)
    }

    Triggers.subscribe()
    {:ok, state, {:continue, :sync}}
  end

  @impl true
  def handle_continue(:sync, state) do
    do_sync(state)
    Process.send_after(self(), :sweep, state.sweep_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sync, _from, state) do
    {:reply, do_sync(state), state}
  end

  @impl true
  def handle_info({:workflow_triggers_changed, _graph_id}, state) do
    do_sync(state)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    do_sync(state)
    Process.send_after(self(), :sweep, state.sweep_ms)
    {:noreply, state}
  end

  defp do_sync(state) do
    desired = Map.new(Triggers.list_source_triggers(), &{&1.id, &1})

    running =
      state.registry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
      |> Map.new(fn {id, pid, fingerprint} -> {id, {pid, fingerprint}} end)

    stale =
      for {id, {pid, fingerprint}} <- running,
          stale_source?(Map.get(desired, id), fingerprint) do
        DynamicSupervisor.terminate_child(state.supervisor, pid)
        id
      end

    running = Map.drop(running, stale)

    for {id, trigger} <- desired, not Map.has_key?(running, id) do
      case DynamicSupervisor.start_child(state.supervisor, source_spec(trigger, state)) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> Triggers.mark_errored(trigger, {:start_source, reason})
      end
    end

    :ok
  end

  defp stale_source?(nil, _fingerprint), do: true
  defp stale_source?(%Trigger{} = trigger, fingerprint), do: fingerprint != fingerprint(trigger)

  defp source_spec(%Trigger{mode: :polling} = trigger, state) do
    {Poller, trigger_id: trigger.id, registry: state.registry, fingerprint: fingerprint(trigger)}
  end

  defp source_spec(%Trigger{mode: :stream} = trigger, state) do
    {StreamSource,
     trigger_id: trigger.id, registry: state.registry, fingerprint: fingerprint(trigger)}
  end
end
