defmodule Hermitscale.Triggers.Runtime.StreamSource do
  @moduledoc """
  Generic runtime for one stream-mode trigger (WebSocket, SSE, queue consumer).

  Owns the process lifecycle — registration, connect, reconnect backoff — and
  delegates protocol work to the trigger module: `init_stream/2` opens the
  connection from inside this process (so connection messages arrive here),
  and every inbound message is translated through `handle_event/2` into zero
  or more dispatcher firings.

  Repeated connection failures back off exponentially; past the threshold the
  trigger is flagged `:errored` and the process stops.
  """

  use GenServer, restart: :transient

  require Logger

  alias Hermitscale.Triggers
  alias Hermitscale.Triggers.Dispatcher

  @base_backoff_ms 1_000
  @max_backoff_ms 60_000
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
      stream: nil,
      connected?: false,
      failures: 0,
      failure_threshold: Keyword.get(opts, :failure_threshold, @failure_threshold)
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: connect(state)

  @impl true
  def handle_info(:connect, state), do: connect(state)

  def handle_info(message, %{connected?: true} = state) do
    case safe_handle_event(state, message) do
      {:fire, payloads, stream} ->
        Enum.each(payloads, &Dispatcher.fire(state.trigger, &1))
        {:noreply, %{state | stream: stream}}

      {:noreply, stream} ->
        {:noreply, %{state | stream: stream}}

      {:reconnect, reason, stream} ->
        Logger.info(
          "stream reconnecting trigger_id=#{state.trigger.id} reason=#{inspect(reason)}"
        )

        state = close(%{state | stream: stream}, {:reconnect, reason})
        {:noreply, schedule_connect(state, @base_backoff_ms)}

      {:stop, reason} ->
        {:stop, reason, state}

      {:error, reason} ->
        state = close(state, {:handler_error, reason})
        fail(state, reason)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, %{connected?: true} = state) do
    close(state, reason)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp connect(state) do
    # Credentials are re-resolved on every (re)connect so rotated tokens are
    # picked up; a resolution failure counts as a connection failure.
    with {:ok, ctx} <- Triggers.source_ctx(state.trigger),
         {:ok, stream} <- safe_init_stream(state, ctx) do
      {:noreply, %{state | stream: stream, connected?: true, failures: 0}}
    else
      {:error, reason} -> fail(state, reason)
    end
  end

  defp safe_init_stream(state, ctx) do
    case state.module.init_stream(state.params, ctx) do
      {:ok, stream} -> {:ok, stream}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_init_stream_return, other}}
    end
  rescue
    exception -> {:error, {exception, __STACKTRACE__}}
  end

  defp safe_handle_event(state, message) do
    state.module.handle_event(message, state.stream)
  rescue
    exception -> {:error, {exception, __STACKTRACE__}}
  end

  defp close(state, reason) do
    if state.connected? and function_exported?(state.module, :terminate_stream, 2) do
      state.module.terminate_stream(reason, state.stream)
    end

    %{state | stream: nil, connected?: false}
  rescue
    _exception -> %{state | stream: nil, connected?: false}
  end

  defp fail(state, reason) do
    failures = state.failures + 1

    Logger.warning(
      "stream source failed trigger_id=#{state.trigger.id} failures=#{failures} " <>
        "reason=#{inspect(reason)}"
    )

    if failures >= state.failure_threshold do
      Triggers.mark_errored(state.trigger, reason)
      {:stop, :normal, state}
    else
      backoff = min(Bitwise.bsl(@base_backoff_ms, failures), @max_backoff_ms)
      {:noreply, schedule_connect(%{state | failures: failures}, backoff)}
    end
  end

  defp schedule_connect(state, ms) do
    Process.send_after(self(), :connect, ms)
    state
  end
end
