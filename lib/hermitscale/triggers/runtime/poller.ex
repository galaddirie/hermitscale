defmodule Hermitscale.Triggers.Runtime.Poller do
  @moduledoc """
  Generic runtime for one polling-mode trigger.

  Drives the trigger module's `poll/3` on a jittered interval, dispatches each
  returned event through the dispatcher, and persists the cursor after the
  batch. Provider errors back off exponentially; past a consecutive-failure
  threshold the trigger is flagged `:errored` in the database and the process
  stops instead of burning supervisor restarts.

  The trigger module is called inside try/rescue: a buggy trigger flips its
  own row to errored rather than crash-looping the shared source supervisor.
  """

  use GenServer, restart: :transient

  require Logger

  alias Hermitscale.Triggers
  alias Hermitscale.Triggers.Dispatcher

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
    trigger = Triggers.get_trigger!(Keyword.fetch!(opts, :trigger_id))
    module = Triggers.catalog_module!(trigger)
    params = Triggers.cast_params!(trigger)

    state = %{
      trigger: trigger,
      module: module,
      params: params,
      cursor: trigger.cursor || %{},
      interval: params[:poll_interval_ms] || @default_interval_ms,
      failures: 0,
      failure_threshold: Keyword.get(opts, :failure_threshold, @failure_threshold)
    }

    # First poll is jittered so a fleet of pollers restarted together does not
    # stampede the provider.
    schedule_poll(:rand.uniform(min(state.interval, 5_000)))
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    # Credentials are re-resolved every poll so rotated tokens stay fresh; a
    # resolution failure is a poll failure (backoff, then errored).
    with {:ok, ctx} <- Triggers.source_ctx(state.trigger),
         {:ok, events, cursor} <- safe_poll(state, ctx) do
      case dispatch_events(state, events) do
        :ok ->
          if cursor != state.cursor, do: Triggers.persist_cursor(state.trigger, cursor)
          schedule_poll(jittered(state.interval))
          {:noreply, %{state | cursor: cursor, failures: 0}}

        :disabled ->
          {:stop, :normal, state}
      end
    else
      {:error, reason} -> fail(state, reason)
    end
  end

  defp safe_poll(state, ctx) do
    case state.module.poll(state.params, state.cursor, ctx) do
      {:ok, events, cursor} when is_list(events) and is_map(cursor) -> {:ok, events, cursor}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_poll_return}
    end
  rescue
    _exception -> {:error, :source_callback_failed}
  end

  defp dispatch_events(state, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      payload = Map.fetch!(event, :payload)
      key = Map.get(event, :key) || default_key(payload)

      case Dispatcher.fire(state.trigger, payload, idempotency_key: key) do
        {:error, :disabled} -> {:halt, :disabled}
        _dispatched_deduped_or_rejected -> {:cont, :ok}
      end
    end)
  end

  # Fallback event identity when the source offers no natural key. phash2 is
  # stable for equal payloads within a runtime, which is the window replays
  # actually happen in; sources with real ids should supply `:key`.
  defp default_key(payload), do: "event-#{:erlang.phash2(payload, 4_294_967_296)}"

  defp fail(state, reason) do
    failures = state.failures + 1

    Logger.warning("Trigger poll failed", trigger_id: state.trigger.id, failures: failures)

    if failures >= state.failure_threshold do
      Triggers.mark_errored(state.trigger, reason)
      {:stop, :normal, state}
    else
      schedule_poll(backoff(state.interval, failures))
      {:noreply, %{state | failures: failures}}
    end
  end

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
