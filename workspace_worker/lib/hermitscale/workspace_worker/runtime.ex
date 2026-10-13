defmodule Hermitscale.WorkspaceWorker.Runtime do
  @moduledoc "Journaled, fenced Harness operations with deadlines and verified writer cleanup."
  use GenServer
  alias Hermitscale.WorkspaceWorker.Journal

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  def execute(server, command), do: GenServer.call(server, {:execute, command}, 60_000)

  @impl true
  def init(options) do
    {:ok,
     %{
       journal: Keyword.fetch!(options, :journal),
       adapter: Keyword.fetch!(options, :adapter),
       activity: Keyword.get(options, :activity_adapter, Hermitscale.WorkspaceWorker.Activity),
       config: Keyword.fetch!(options, :config),
       handles: %{}
     }, {:continue, :recover_writer}}
  end

  @impl true
  def handle_continue(:recover_writer, state) do
    case Journal.active_operation(state.journal) do
      {:ok, %{"operation_id" => id, "status" => "uncertain"}} ->
        case state.adapter.recover_termination(state.config) do
          {:ok, proof} ->
            _release_hold = state.activity.release(state.config)
            :ok = Journal.confirm_termination(state.journal, id, "interrupted", json_value(proof))

          {:error, _reason} ->
            :ok
        end

      {:error, :no_active_operation} ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, "[REDACTED]") |> Map.put(:message, "[REDACTED]")

  @impl true
  def handle_call({:execute, command}, _from, state) do
    case {Journal.execute(state.journal, command), command} do
      {{:ok, %{"status" => "accepted"}} = reply, %{"type" => "start"}} ->
        id = command["operation_id"]
        :ok = Journal.mark_running(state.journal, id)

        {:ok, deadline, 0} = DateTime.from_iso8601(command["deadline"])

        started_at = System.monotonic_time(:millisecond)

        start_result =
          with :ok <- state.activity.acquire(deadline, state.config),
               do: state.adapter.start(command, state.config)

        case start_result do
          {:ok, handle} ->
            {:ok, deadline, 0} = DateTime.from_iso8601(command["deadline"])

            Process.send_after(
              self(),
              {:deadline, id},
              max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 1)
            )

            Process.send_after(self(), {:poll, id}, 100)

            {:reply, reply,
             put_in(state.handles[id], %{handle: handle, closing: nil, started_at: started_at})}

          {:error, reason} ->
            :ok =
              Journal.append_provider_event(state.journal, id, %{
                "kind" => "runtime_unavailable",
                "reason" => inspect(reason, limit: 2)
              })

            :ok = Journal.terminal_observed(state.journal, id, "failed")

            case state.adapter.cleanup_failed_start(state.config) do
              {:ok, proof} ->
                _release_hold = state.activity.release(state.config)

                :ok =
                  Journal.confirm_termination(
                    state.journal,
                    id,
                    "failed",
                    measured_proof(proof, started_at)
                  )

              {:error, _reason} ->
                :ok
            end

            {:reply, {:error, :runtime_unavailable}, state}
        end

      {{:ok, %{"termination_confirmed" => true}} = reply, %{"type" => "cancel"}} ->
        {:reply, reply, state}

      {{:ok, _status}, %{"type" => "cancel"}} ->
        case Map.fetch(state.handles, command["operation_id"]) do
          {:ok, %{handle: handle}} ->
            _interrupt = state.adapter.cancel(handle)
            next = begin_cleanup(state, command["operation_id"], handle, "interrupted")
            {:reply, Journal.status(state.journal, command["operation_id"]), next}

          :error ->
            {:reply, {:error, :requires_reconciliation}, state}
        end

      {{:ok, %{"approval_delivered" => true}} = reply, %{"type" => "approve"}} ->
        {:reply, reply, state}

      {{:ok, _status} = reply, %{"type" => "approve", "payload" => payload}} ->
        case Map.fetch(state.handles, command["operation_id"]) do
          {:ok, %{handle: handle, closing: nil}} ->
            case state.adapter.approve(handle, payload["request_id"], payload["response"]) do
              :ok ->
                :ok = Journal.approval_delivered(state.journal, command["command_id"])
                {:reply, reply, state}

              {:error, _reason} ->
                {:reply, {:error, :approval_unavailable}, state}
            end

          :error ->
            {:reply, {:error, :requires_reconciliation}, state}

          {:ok, _closing} ->
            {:reply, {:error, :operation_terminal}, state}
        end

      {reply, _command} ->
        {:reply, reply, state}
    end
  end

  @impl true
  def handle_info({:poll, id}, state) do
    case Map.fetch(state.handles, id) do
      :error ->
        {:noreply, state}

      {:ok, %{closing: outcome, handle: handle}} when is_binary(outcome) ->
        {:noreply, finish_cleanup(state, id, handle, outcome)}

      {:ok, %{handle: handle}} ->
        case state.adapter.poll(handle) do
          {:ok, events, handle} ->
            Enum.each(events, fn event ->
              payload = %{
                "type" => Atom.to_string(event.type),
                "provider_cursor" => event.sequence,
                "payload" => json_value(event.payload)
              }

              payload =
                case Map.get(event, :provider_session_id) do
                  nil -> payload
                  provider_id -> Map.put(payload, "provider_session_id", provider_id)
                end

              payload =
                case Map.get(event, :request_id) do
                  nil -> payload
                  request_id -> Map.put(payload, "request_id", request_id)
                end

              :ok = Journal.append_provider_event(state.journal, id, payload)
            end)

            case Enum.find(
                   events,
                   &(&1.type in [
                       :turn_completed,
                       :turn_failed,
                       :turn_interrupted,
                       :session_failed
                     ])
                 ) do
              nil ->
                Process.send_after(self(), {:poll, id}, 100)

                {:noreply,
                 put_in(
                   state.handles[id],
                   Map.merge(Map.fetch!(state.handles, id), %{handle: handle, closing: nil})
                 )}

              event ->
                outcome =
                  case event.type do
                    :turn_completed -> "completed"
                    :turn_interrupted -> "interrupted"
                    type when type in [:turn_failed, :session_failed] -> "failed"
                  end

                {:noreply, begin_cleanup(state, id, handle, outcome)}
            end

          {:error, _reason} ->
            :ok =
              Journal.append_provider_event(state.journal, id, %{
                "kind" => "history_unavailable",
                "requires_reconciliation" => true
              })

            {:noreply, begin_cleanup(state, id, handle, "failed")}
        end
    end
  end

  def handle_info({:deadline, id}, state) do
    case Map.fetch(state.handles, id) do
      :error ->
        {:noreply, state}

      {:ok, %{handle: handle}} ->
        _interrupt = state.adapter.cancel(handle)
        {:noreply, begin_cleanup(state, id, handle, "interrupted")}
    end
  end

  defp begin_cleanup(state, id, handle, outcome) do
    :ok = Journal.terminal_observed(state.journal, id, outcome)
    _close = state.adapter.close(handle)

    finish_cleanup(
      put_in(
        state.handles[id],
        Map.merge(Map.fetch!(state.handles, id), %{handle: handle, closing: outcome})
      ),
      id,
      handle,
      outcome
    )
  end

  defp finish_cleanup(state, id, handle, outcome) do
    case state.adapter.verify_termination(handle) do
      {:ok, evidence} ->
        _release_hold = state.activity.release(state.config)

        :ok =
          Journal.confirm_termination(
            state.journal,
            id,
            outcome,
            measured_proof(evidence, state.handles[id].started_at)
          )

        %{state | handles: Map.delete(state.handles, id)}

      {:error, :writer_still_running} ->
        Process.send_after(self(), {:poll, id}, 100)
        state
    end
  end

  defp measured_proof(proof, started_at) do
    proof
    |> json_value()
    |> Map.put("compute_milliseconds", max(System.monotonic_time(:millisecond) - started_at, 0))
  end

  defp json_value(%_{} = struct), do: struct |> Map.from_struct() |> json_value()

  defp json_value(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json_value(value)} end)

  defp json_value(list) when is_list(list), do: Enum.map(list, &json_value/1)

  defp json_value(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp json_value(value) when is_binary(value) or is_number(value) or value in [nil, true, false],
    do: value

  defp json_value(value), do: inspect(value, limit: 10)
end
