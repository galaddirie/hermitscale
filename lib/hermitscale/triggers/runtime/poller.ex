defmodule Hermitscale.Triggers.Runtime.Poller do
  @moduledoc """
  Generic runtime for one polling-mode trigger.

  Drives the trigger module's `poll/3` on a jittered interval, dispatches each
  returned event through the dispatcher, and persists the cursor after the
  batch. Provider errors back off exponentially; past a consecutive-failure
  threshold the trigger is flagged `:errored` in the database and the process
  stops instead of burning supervisor restarts.

  Callback defects are logged with their stacktrace and quarantine the source
  immediately. Only expected provider and dispatch failures consume the retry
  budget. A failed batch retains its cursor so the same keys are replayed.
  """

  use GenServer, restart: :transient

  require Logger

  alias Hermitscale.Triggers
  alias Hermitscale.Triggers.Dispatcher
  alias Hermitscale.Triggers.Runtime.Callback
  alias Hermitscale.Triggers.Trigger
  alias Hermitscale.Workflows.Run

  @default_interval_ms 60_000
  @max_backoff_ms 5 * 60_000
  @failure_threshold 10

  def start_link(opts) do
    trigger_id = Keyword.fetch!(opts, :trigger_id)
    registry = Keyword.get(opts, :registry, Hermitscale.Triggers.Registry)
    fingerprint = Keyword.get(opts, :fingerprint)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {registry, trigger_id, fingerprint}}
    )
  end

  @impl true
  def init(opts) do
    {:ok, opts, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, opts) do
    case Triggers.get_trigger(Keyword.fetch!(opts, :trigger_id)) do
      %Trigger{status: :enabled} = trigger -> load(trigger, opts)
      %Trigger{} -> {:stop, :normal, opts}
      nil -> {:stop, :normal, opts}
    end
  end

  defp load(trigger, opts) do
    module = Triggers.catalog_module!(trigger)
    params = Triggers.cast_params!(trigger)

    state = %{
      trigger: trigger,
      module: module,
      params: params,
      cursor: trigger.cursor,
      interval: Map.get(params, :poll_interval_ms, @default_interval_ms),
      failures: 0,
      failure_threshold: Keyword.get(opts, :failure_threshold, @failure_threshold)
    }

    # First poll is jittered so a fleet of pollers restarted together does not
    # stampede the provider.
    schedule_poll(
      Keyword.get_lazy(opts, :initial_poll_delay_ms, fn ->
        :rand.uniform(min(state.interval, 5_000))
      end)
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    # Credentials are re-resolved every poll so rotated tokens stay fresh; a
    # resolution failure is a poll failure (backoff, then errored).
    with {:ok, ctx} <- Triggers.source_ctx(state.trigger),
         {:ok, events, cursor} <- poll(state, ctx),
         :ok <- dispatch_events(state, events) do
      if cursor != state.cursor, do: :ok = Triggers.persist_cursor(state.trigger, cursor)
      schedule_poll(jittered(state.interval))
      {:noreply, %{state | cursor: cursor, failures: 0}}
    else
      {:callback_failed, reason} ->
        quarantine(state, reason)

      {:error, :disabled} ->
        {:stop, :normal, state}

      {:error, :execution_actor_ineligible} ->
        {:stop, :normal, state}

      {:error, {:connection_not_ready, _node, reason}}
      when reason in [:needs_reauthorization, :account_not_found, :insufficient_scopes] ->
        {:stop, :normal, state}

      {:error, reason} ->
        fail(state, reason)
    end
  end

  defp poll(state, ctx) do
    case Callback.invoke(state.module, :poll, [state.params, state.cursor, ctx]) do
      {:ok, events, cursor} when is_list(events) and is_map(cursor) ->
        if Enum.all?(events, &valid_event?/1),
          do: {:ok, events, cursor},
          else: {:callback_failed, :invalid_poll_events}

      {:error, _reason} = error ->
        error

      {:callback_failed, _reason} = error ->
        error

      _invalid_return ->
        {:callback_failed, :invalid_poll_return}
    end
  end

  defp valid_event?(%{payload: payload} = event) when is_map(payload) do
    case Map.fetch(event, :key) do
      {:ok, key} -> is_binary(key) and key != ""
      :error -> true
    end
  end

  defp valid_event?(_event), do: false

  defp dispatch_events(state, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      payload = Map.fetch!(event, :payload)
      key = Map.get_lazy(event, :key, fn -> default_key(payload) end)

      case Dispatcher.fire(state.trigger, payload, idempotency_key: key) do
        {:ok, %Run{}} -> {:cont, :ok}
        {:ok, :deduped} -> {:cont, :ok}
        {:error, :rejected} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Fallback event identity when the source offers no natural key. phash2 is
  # stable for equal payloads within a runtime, which is the window replays
  # actually happen in; sources with real ids should supply `:key`.
  defp default_key(payload), do: "event-#{:erlang.phash2(payload, 4_294_967_296)}"

  defp fail(state, reason) do
    failures = state.failures + 1

    Logger.warning(
      "Trigger #{state.trigger.id} poll failed: #{error_kind(reason)} (attempt #{failures})",
      trigger_id: state.trigger.id,
      failures: failures
    )

    if failures >= state.failure_threshold do
      {:ok, _trigger} = Triggers.mark_errored(state.trigger, reason)
      {:stop, :normal, state}
    else
      schedule_poll(backoff(state.interval, failures))
      {:noreply, %{state | failures: failures}}
    end
  end

  defp quarantine(state, reason) do
    Logger.error("Trigger #{state.trigger.id} callback quarantined: #{inspect(reason)}")
    {:ok, _trigger} = Triggers.mark_errored(state.trigger, reason)
    {:stop, :normal, state}
  end

  # Dependency errors may carry response bodies; only their category is logged.
  defp error_kind(reason) when is_atom(reason), do: reason
  defp error_kind(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: elem(reason, 0)
  defp error_kind(_reason), do: :dependency_failure

  defp backoff(interval, failures) do
    interval
    |> Bitwise.bsl(failures)
    |> min(@max_backoff_ms)
    |> jittered()
  end

  defp jittered(ms) do
    spread = max(div(ms, 10), 1)
    ms - div(spread, 2) + :rand.uniform(spread)
  end

  defp schedule_poll(ms), do: Process.send_after(self(), :poll, ms)
end
