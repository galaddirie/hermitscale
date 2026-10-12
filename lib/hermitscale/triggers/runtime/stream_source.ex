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
  alias Hermitscale.Triggers.Runtime.Callback
  alias Hermitscale.Triggers.Trigger
  alias Hermitscale.Workflows.Run

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
      stream: nil,
      connected?: false,
      failures: 0,
      failure_threshold: Keyword.get(opts, :failure_threshold, @failure_threshold)
    }

    connect(state)
  end

  @impl true
  def handle_info(:connect, %{connected?: false} = state), do: connect(state)
  def handle_info(:connect, %{connected?: true} = state), do: {:noreply, state}

  def handle_info(message, %{connected?: true} = state) do
    case Callback.invoke(state.module, :handle_event, [message, state.stream]) do
      {:fire, payloads, stream} when is_list(payloads) ->
        if Enum.all?(payloads, &is_map/1) do
          case dispatch_payloads(state.trigger, payloads) do
            :ok ->
              failures = if payloads == [], do: state.failures, else: 0
              {:noreply, %{state | stream: stream, failures: failures}}

            {:error, :disabled} ->
              {:stop, :normal, %{state | stream: stream}}

            {:error, reason} ->
              disconnect_then(%{state | stream: stream}, reason, &fail(&1, reason))
          end
        else
          quarantine(state, :invalid_stream_return)
        end

      {:noreply, stream} ->
        {:noreply, %{state | stream: stream}}

      {:reconnect, reason, stream} ->
        Logger.info("Stream reconnecting", trigger_id: state.trigger.id)

        disconnect_then(%{state | stream: stream}, {:reconnect, reason}, fn state ->
          {:noreply, schedule_connect(state, @base_backoff_ms)}
        end)

      {:stop, reason} ->
        {:stop, reason, state}

      {:error, reason} ->
        disconnect_then(state, {:handler_error, reason}, &fail(&1, reason))

      {:callback_failed, reason} ->
        quarantine(state, reason)

      _invalid_return ->
        quarantine(state, :invalid_stream_return)
    end
  end

  # Connection protocols may deliver late messages after a disconnect.
  def handle_info(_message, %{connected?: false} = state), do: {:noreply, state}

  @impl true
  def terminate(reason, %{connected?: true} = state) do
    case disconnect(state, reason) do
      {:ok, _state} -> :ok
      {:callback_failed, reason, _state} -> Triggers.mark_errored(state.trigger, reason)
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp connect(state) do
    # Credentials are re-resolved on every (re)connect so rotated tokens are
    # picked up; a resolution failure counts as a connection failure.
    with {:ok, ctx} <- Triggers.source_ctx(state.trigger),
         {:ok, stream} <- init_stream(state, ctx) do
      # Reconnecting establishes transport health, not successful workflow
      # delivery. Preserve the budget until an event dispatch succeeds.
      {:noreply, %{state | stream: stream, connected?: true}}
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

  defp init_stream(state, ctx) do
    case Callback.invoke(state.module, :init_stream, [state.params, ctx]) do
      {:ok, stream} -> {:ok, stream}
      {:error, reason} -> {:error, reason}
      {:callback_failed, _reason} = error -> error
      _invalid_return -> {:callback_failed, :invalid_init_stream_return}
    end
  end

  defp dispatch_payloads(trigger, payloads) do
    Enum.reduce_while(payloads, :ok, fn payload, :ok ->
      case Dispatcher.fire(trigger, payload) do
        {:ok, %Run{}} -> {:cont, :ok}
        {:ok, :deduped} -> {:cont, :ok}
        {:error, :rejected} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp disconnect_then(state, reason, next) do
    case disconnect(state, reason) do
      {:ok, state} -> next.(state)
      {:callback_failed, reason, state} -> quarantine(state, reason)
    end
  end

  defp disconnect(state, reason) do
    disconnected = %{state | stream: nil, connected?: false}

    if state.connected? and function_exported?(state.module, :terminate_stream, 2) do
      case Callback.invoke(state.module, :terminate_stream, [reason, state.stream]) do
        :ok -> {:ok, disconnected}
        {:callback_failed, reason} -> {:callback_failed, reason, disconnected}
        _invalid_return -> {:callback_failed, :invalid_terminate_stream_return, disconnected}
      end
    else
      {:ok, disconnected}
    end
  end

  defp fail(state, reason) when reason in [:disabled, :execution_actor_ineligible],
    do: {:stop, :normal, state}

  defp fail(state, {:connection_not_ready, _node, reason})
       when reason in [:needs_reauthorization, :account_not_found, :insufficient_scopes],
       do: {:stop, :normal, state}

  defp fail(state, reason) do
    failures = state.failures + 1

    Logger.warning(
      "Trigger #{state.trigger.id} stream source failed: #{error_kind(reason)} (attempt #{failures})",
      trigger_id: state.trigger.id,
      failures: failures
    )

    if failures >= state.failure_threshold do
      {:ok, _trigger} = Triggers.mark_errored(state.trigger, reason)
      {:stop, :normal, state}
    else
      backoff = min(Bitwise.bsl(@base_backoff_ms, failures), @max_backoff_ms)
      {:noreply, schedule_connect(%{state | failures: failures}, backoff)}
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

  defp schedule_connect(state, ms) do
    Process.send_after(self(), :connect, ms)
    state
  end
end
