defmodule Hermitscale.WorkspaceWorker.Journal do
  @moduledoc """
  Single-writer durable acceptance journal.

  Every accepted mutation is appended and fsynced before a reply. A restart marks
  unfinished operations uncertain; it never replays a provider side effect.
  Generations cannot advance until external writer termination is reconciled.
  Storage and event limits fail closed rather than silently rotating history.
  """
  use GenServer

  alias Hermitscale.WorkspaceProtocol.V1, as: Protocol

  @unfinished ~w(accepted running awaiting_approval cancel_requested awaiting_termination uncertain)

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  def execute(server, command), do: GenServer.call(server, {:execute, command})
  def status(server, operation_id), do: GenServer.call(server, {:status, operation_id})
  def epoch(server), do: GenServer.call(server, :epoch)
  def active_operation(server), do: GenServer.call(server, :active_operation)

  def approval_delivered(server, command_id),
    do: GenServer.call(server, {:approval_delivered, command_id})

  @doc "Begins an explicitly fenced checkpoint-recovery epoch after writer termination."
  def begin_recovery_epoch(server, operation_id, generation, evidence),
    do: GenServer.call(server, {:begin_recovery_epoch, operation_id, generation, evidence})

  def mark_running(server, operation_id), do: GenServer.call(server, {:running, operation_id})

  def append_provider_event(server, operation_id, payload),
    do: GenServer.call(server, {:provider, operation_id, payload})

  def terminal_observed(server, operation_id, outcome),
    do: GenServer.call(server, {:terminal_observed, operation_id, outcome})

  @doc "Internal reconciliation entrypoint; callers must independently verify writer termination."
  def confirm_termination(server, operation_id, outcome, evidence),
    do: GenServer.call(server, {:termination_confirmed, operation_id, outcome, evidence})

  @impl true
  def init(options) do
    path = Keyword.fetch!(options, :path)
    workspace_id = Keyword.fetch!(options, :workspace_id)
    max_bytes = Keyword.get(options, :max_bytes, 64 * 1_024 * 1_024)
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)

    with {:ok, data, valid_bytes} <- load(path, workspace_id, max_bytes),
         {:ok, file} <- :file.open(String.to_charlist(path), [:read, :write, :raw, :binary]),
         :ok <- File.chmod(path, 0o600),
         {:ok, ^valid_bytes} <- :file.position(file, valid_bytes),
         :ok <- :file.truncate(file) do
      state = %{
        data: recover(data),
        file: file,
        max_bytes: max_bytes,
        secrets: Keyword.get(options, :secrets, []),
        provider_env_file: Keyword.get(options, :provider_env_file)
      }

      case persist(state) do
        {:ok, state} ->
          {:ok, state}

        {:error, reason} ->
          :file.close(file)
          {:stop, {:journal_unavailable, reason}}
      end
    else
      {:error, reason} -> {:stop, {:journal_unavailable, reason}}
    end
  end

  @impl true
  def terminate(_reason, state), do: :file.close(state.file)

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, "[REDACTED]") |> Map.put(:message, "[REDACTED]")

  @impl true
  def handle_call(:epoch, _from, state), do: {:reply, state.data["epoch"], state}

  def handle_call(:active_operation, _from, state) do
    reply =
      case state.data["active_operation"] do
        nil -> {:error, :no_active_operation}
        id -> operation(state.data, id)
      end

    {:reply, reply, state}
  end

  def handle_call({:approval_delivered, command_id}, _from, state) do
    persist_reply(state, put_in(state.data, ["delivered_approvals", command_id], true))
  end

  def handle_call({:status, id}, _from, state), do: {:reply, operation(state.data, id), state}

  def handle_call({:begin_recovery_epoch, id, generation, evidence}, _from, state) do
    with true <- state.data["active_operation"] == nil,
         {:ok, %{"termination_confirmed" => true}} <- operation(state.data, id),
         true <- is_integer(generation) and generation > state.data["generation"],
         true <- is_map(evidence) and map_size(evidence) > 0 do
      prior_epoch = state.data["epoch"]

      data =
        state.data
        |> new_epoch()
        |> Map.put("generation", generation)
        |> event(
          id,
          "recovered",
          Protocol.redact_payload(
            %{
              "reason" => "checkpoint_recovery",
              "previous_epoch" => prior_epoch,
              "generation" => generation,
              "evidence" => evidence
            },
            state.secrets
          )
        )

      case persist(%{state | data: data}) do
        {:ok, next} -> {:reply, {:ok, next.data["epoch"]}, next}
        {:error, reason} -> {:stop, {:journal_unavailable, reason}, {:error, reason}, state}
      end
    else
      false -> {:reply, {:error, :recovery_not_fenced}, state}
      {:ok, _operation} -> {:reply, {:error, :termination_unconfirmed}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:execute, command}, _from, state) do
    state = %{state | secrets: current_secrets(state) |> Enum.uniq()}

    with {:ok, command} <- Protocol.validate_command(command),
         :ok <- workspace_matches(command, state.data),
         {:ok, mode} <- command_mode(command, state.data),
         {:ok, data} <- apply_command(mode, command, state.data) do
      case persist(%{state | data: data}) do
        {:ok, next} -> {:reply, response(command, next.data), next}
        {:error, reason} -> {:stop, {:journal_unavailable, reason}, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:running, id}, _from, state) do
    with {:ok, %{"status" => "accepted"} = op} <- operation(state.data, id) do
      op = Map.put(op, "status", "running")
      data = state.data |> put_operation(id, op) |> event(id, "running", %{})
      persist_reply(state, data)
    else
      {:ok, _operation} -> {:reply, {:error, :not_accepted}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:provider, id, payload}, _from, state) do
    state = %{state | secrets: current_secrets(state) |> Enum.uniq()}

    with {:ok, _operation} <- operation(state.data, id),
         true <- is_map(payload) do
      secrets = current_secrets(state)
      data = event(state.data, id, "provider", Protocol.redact_payload(payload, secrets))

      data =
        case Map.fetch(payload, "provider_session_id") do
          {:ok, provider_id} when is_binary(provider_id) ->
            put_in(data, ["operations", id, "provider_session_id"], provider_id)

          :error ->
            data
        end

      data =
        case payload do
          %{"type" => "approval_requested", "request_id" => request_id, "payload" => request} ->
            data
            |> put_in(
              ["operations", id, "approval_request"],
              Protocol.redact_payload(Map.put(request, "request_id", request_id), secrets)
            )
            |> put_in(["operations", id, "status"], "awaiting_approval")

          %{"type" => "approval_resolved"} ->
            data
            |> put_in(["operations", id, "approval_request"], nil)
            |> put_in(["operations", id, "status"], "running")

          _other_provider_event ->
            data
        end

      persist_reply(state, data)
    else
      false -> {:reply, {:error, :invalid_payload}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:terminal_observed, id, outcome}, _from, state) do
    with {:ok, op} <- operation(state.data, id),
         true <- op["status"] in @unfinished,
         true <- outcome in ~w(completed failed interrupted) do
      op = Map.merge(op, %{"status" => "awaiting_termination", "observed_outcome" => outcome})

      data =
        state.data
        |> put_operation(id, op)
        |> event(id, "terminal_observed", %{"outcome" => outcome})

      persist_reply(state, data)
    else
      false -> {:reply, {:error, :invalid_transition}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:termination_confirmed, id, outcome, evidence}, _from, state) do
    with {:ok, op} <- operation(state.data, id),
         true <- op["status"] in @unfinished,
         true <- outcome in ~w(completed failed interrupted),
         true <- is_map(evidence) and map_size(evidence) > 0 do
      op = Map.merge(op, %{"status" => outcome, "termination_confirmed" => true})

      op =
        case Map.fetch(evidence, "compute_milliseconds") do
          {:ok, milliseconds} when is_integer(milliseconds) and milliseconds >= 0 ->
            Map.put(op, "compute_milliseconds", milliseconds)

          :error ->
            op
        end

      data =
        state.data
        |> put_operation(id, op)
        |> Map.put("active_operation", nil)
        |> event(
          id,
          "termination_confirmed",
          Protocol.redact_payload(%{"outcome" => outcome, "evidence" => evidence}, state.secrets)
        )

      persist_reply(state, data)
    else
      false -> {:reply, {:error, :invalid_termination_evidence}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp persist_reply(state, data) do
    case persist(%{state | data: data}) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, reason} -> {:stop, {:journal_unavailable, reason}, {:error, reason}, state}
    end
  end

  defp current_secrets(%{provider_env_file: nil, secrets: secrets}), do: secrets

  defp current_secrets(%{provider_env_file: path, secrets: secrets}) do
    env = path |> File.read!() |> JSON.decode!()
    secrets ++ Map.values(Map.take(env, ["OPENAI_API_KEY"]))
  end

  defp workspace_matches(command, data) do
    case command["workspace_id"] == data["workspace_id"] do
      true -> :ok
      false -> {:error, :workspace_mismatch}
    end
  end

  defp command_mode(command, data) do
    fingerprint = Protocol.payload_digest(command)

    case Map.fetch(data["commands"], command["command_id"]) do
      {:ok, ^fingerprint} ->
        {:ok, :duplicate}

      {:ok, _fingerprint} ->
        {:error, :command_conflict}

      :error ->
        options =
          if command["type"] in ~w(inspect cancel read_events ack_events),
            do: [],
            else: [now: DateTime.utc_now()]

        with {:ok, _command} <- Protocol.validate_command(command, options) do
          {:ok, :new}
        end
    end
  end

  defp apply_command(:duplicate, _command, data), do: {:ok, data}

  defp apply_command(:new, command, data) do
    with {:ok, data} <- mutate(command, data),
         true <- map_size(data["commands"]) < 10_000 do
      {:ok, put_in(data, ["commands", command["command_id"]], Protocol.payload_digest(command))}
    else
      false -> {:error, :command_limit}
      {:error, _reason} = error -> error
    end
  end

  defp mutate(%{"type" => "start"} = command, data) do
    id = command["operation_id"]
    generation = command["generation"]

    cond do
      Map.has_key?(data["operations"], id) ->
        {:error, :operation_already_exists}

      generation <= data["generation"] ->
        {:error, :stale_generation}

      data["active_operation"] != nil ->
        {:error, :writer_active}

      true ->
        op = %{
          "operation_id" => id,
          "generation" => generation,
          "status" => "accepted",
          "payload_digest" => command["payload_digest"],
          "cancel_requested" => false,
          "termination_confirmed" => false
        }

        data =
          data
          |> put_operation(id, op)
          |> Map.put("active_operation", id)
          |> Map.put("generation", generation)
          |> event(id, "accepted", %{"generation" => generation})

        {:ok, data}
    end
  end

  defp mutate(%{"type" => "cancel"} = command, data) do
    with {:ok, op} <- current_operation(command, data) do
      cond do
        op["termination_confirmed"] == true ->
          {:ok, data}

        op["status"] in @unfinished ->
          op = Map.merge(op, %{"status" => "cancel_requested", "cancel_requested" => true})

          {:ok,
           data
           |> put_operation(command["operation_id"], op)
           |> event(command["operation_id"], "cancel_requested", %{})}

        true ->
          {:error, :operation_terminal}
      end
    end
  end

  defp mutate(%{"type" => "ack_events", "payload" => payload} = command, data) do
    with {:ok, _op} <- current_operation(command, data),
         {:ok, max_cursor} <- epoch_cursor(data, payload["epoch"]),
         true <- payload["cursor"] <= max_cursor do
      key = command["operation_id"] <> ":" <> payload["epoch"]
      prior = Map.get(data["acks"], key, 0)
      {:ok, put_in(data, ["acks", key], max(prior, payload["cursor"]))}
    else
      false -> {:error, :cursor_ahead}
      {:error, _reason} = error -> error
    end
  end

  defp mutate(%{"type" => "inspect"} = command, data) do
    with {:ok, _op} <- current_operation(command, data), do: {:ok, data}
  end

  defp mutate(%{"type" => "approve", "payload" => payload} = command, data) do
    with {:ok, op} <- current_operation(command, data),
         true <- op["status"] in @unfinished,
         %{"request_id" => request_id} <- op["approval_request"],
         true <- request_id == payload["request_id"] do
      {:ok, event(data, command["operation_id"], "approval_decided", payload)}
    else
      false -> {:error, :operation_terminal}
      nil -> {:error, :approval_not_pending}
      {:error, _reason} = error -> error
    end
  end

  defp mutate(%{"type" => "read_events", "payload" => payload} = command, data) do
    with {:ok, _op} <- current_operation(command, data),
         {:ok, max_cursor} <- epoch_cursor(data, payload["epoch"]),
         true <- payload["cursor"] <= max_cursor do
      {:ok, data}
    else
      false -> {:error, :cursor_ahead}
      {:error, _reason} = error -> error
    end
  end

  defp current_operation(command, data) do
    with {:ok, op} <- operation(data, command["operation_id"]) do
      case command["generation"] == op["generation"] do
        true -> {:ok, op}
        false -> {:error, :generation_mismatch}
      end
    end
  end

  defp response(%{"type" => "read_events", "payload" => payload} = command, data) do
    with {:ok, max_cursor} <- epoch_cursor(data, payload["epoch"]),
         true <- payload["cursor"] <= max_cursor do
      events =
        data["events"]
        |> Enum.filter(
          &(&1["epoch"] == payload["epoch"] and &1["cursor"] > payload["cursor"] and
              &1["operation_id"] == command["operation_id"])
        )
        |> Enum.take(payload["limit"])

      {:ok,
       %{
         "epoch" => payload["epoch"],
         "events" => events,
         "next_cursor" =>
           case List.last(events) do
             nil -> payload["cursor"]
             last -> last["cursor"]
           end
       }}
    else
      false -> {:error, :cursor_ahead}
      {:error, _reason} = error -> error
    end
  end

  defp response(command, data) do
    {:ok, op} = operation(data, command["operation_id"])

    epoch =
      case command["type"] do
        "ack_events" -> command["payload"]["epoch"]
        _other -> data["epoch"]
      end

    ack = Map.get(data["acks"], command["operation_id"] <> ":" <> epoch, 0)

    {:ok,
     Map.merge(op, %{
       "epoch" => data["epoch"],
       "cursor" => data["cursor"],
       "acknowledged_cursor" => ack,
       "approval_delivered" => Map.get(data["delivered_approvals"], command["command_id"], false)
     })}
  end

  defp operation(data, id) do
    case Map.fetch(data["operations"], id) do
      {:ok, op} -> {:ok, op}
      :error -> {:error, :operation_not_found}
    end
  end

  defp put_operation(data, id, op), do: put_in(data, ["operations", id], op)

  defp epoch_cursor(data, epoch) do
    case Map.fetch(data["epochs"], epoch) do
      {:ok, cursor} -> {:ok, cursor}
      :error -> {:error, :history_gap}
    end
  end

  defp event(data, id, type, payload) do
    cursor = data["cursor"] + 1

    event = %{
      "version" => 1,
      "workspace_id" => data["workspace_id"],
      "operation_id" => id,
      "epoch" => data["epoch"],
      "cursor" => cursor,
      "type" => type,
      "payload" => payload
    }

    {:ok, ^event} = Protocol.validate_event(event)

    data
    |> Map.put("cursor", cursor)
    |> Map.put("events", data["events"] ++ [event])
    |> put_in(["epochs", data["epoch"]], cursor)
  end

  defp recover(data) do
    data = Map.put_new(data, "delivered_approvals", %{})

    data =
      case Map.fetch(data, "epoch") do
        {:ok, _epoch} -> data
        :error -> new_epoch(data)
      end

    case data["active_operation"] do
      nil ->
        data

      id ->
        {:ok, op} = operation(data, id)

        data
        |> put_operation(id, Map.put(op, "status", "uncertain"))
        |> event(id, "recovered", %{
          "reason" => "worker_restarted",
          "requires_reconciliation" => true
        })
    end
  end

  defp new_epoch(data) do
    epoch = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    data |> Map.put("epoch", epoch) |> Map.put("cursor", 0) |> put_in(["epochs", epoch], 0)
  end

  defp load(path, workspace_id, max_bytes) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok,
         %{
           "version" => 1,
           "workspace_id" => workspace_id,
           "generation" => 0,
           "active_operation" => nil,
           "operations" => %{},
           "commands" => %{},
           "events" => [],
           "epochs" => %{},
           "acks" => %{}
         }, 0}

      {:ok, binary} when byte_size(binary) <= max_bytes ->
        decode_last(binary, workspace_id)

      {:ok, _binary} ->
        {:error, :journal_full}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_last(binary, workspace_id) do
    pieces = :binary.split(binary, "\n", [:global])
    complete = Enum.drop(pieces, -1)
    valid_bytes = Enum.reduce(complete, 0, &(byte_size(&1) + 1 + &2))

    case List.last(complete) do
      nil ->
        {:error, :incomplete_initial_journal}

      line ->
        case JSON.decode(line) do
          {:ok, %{"version" => 1, "workspace_id" => ^workspace_id} = data} ->
            {:ok, data, valid_bytes}

          {:ok, _data} ->
            {:error, :journal_identity_mismatch}

          {:error, _reason} ->
            {:error, :corrupt_journal}
        end
    end
  end

  defp persist(state) do
    record = JSON.encode!(state.data) <> "\n"

    with true <- length(state.data["events"]) <= 5_000,
         {:ok, offset} <- :file.position(state.file, :eof),
         true <- offset + byte_size(record) <= state.max_bytes,
         :ok <- :file.write(state.file, record),
         :ok <- :file.sync(state.file) do
      {:ok, state}
    else
      false -> {:error, :journal_full}
      {:error, _reason} = error -> error
    end
  end
end
