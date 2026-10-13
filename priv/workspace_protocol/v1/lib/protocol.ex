defmodule Hermitscale.WorkspaceProtocol.V1 do
  @moduledoc """
  Shared JSON protocol for the private workspace control channel.

  Digests use UTF-8 canonical JSON with lexically sorted object keys and SHA-256.
  Deadlines are UTC ISO-8601 timestamps. Remote data never creates atoms.
  """

  @command_keys ~w(version workspace_id operation_id command_id generation payload_digest deadline type payload)
  @event_keys ~w(version workspace_id operation_id epoch cursor type payload)
  @types ~w(start inspect cancel approve read_events)
  @event_types ~w(accepted running cancel_requested approval_decided uncertain recovered provider terminal_observed termination_confirmed runtime_unavailable history_gap)
  @max_command_bytes 65_536
  @max_event_bytes 16_384
  @secret_key ~r/\A(?:secrets|tokens)\z|(?:secret(?:[_-]?key)?|token|password|authorization|credentials?|api[_-]?key)\z/i

  def validate_command(command, options \\ [])

  def validate_command(command, options) when is_map(command) do
    with :ok <- exact_keys(command, @command_keys),
         :ok <- common(command),
         :ok <- identifier(command["command_id"]),
         true <- command["type"] in @types,
         true <- is_integer(command["generation"]) and command["generation"] > 0,
         :ok <- json_object(command["payload"]),
         :ok <- bounded(command, @max_command_bytes),
         :ok <- digest_matches(command),
         :ok <- payload_shape(command["type"], command["payload"]),
         true <- is_binary(command["deadline"]),
         {:ok, deadline, 0} <- DateTime.from_iso8601(command["deadline"]),
         :ok <- deadline_valid(deadline, options) do
      {:ok, command}
    else
      false -> {:error, :invalid_command}
      {:ok, _deadline, _offset} -> {:error, :deadline_must_be_utc}
      {:error, _reason} = error -> error
    end
  end

  def validate_command(_command, _options), do: {:error, :invalid_command}

  def validate_event(event) when is_map(event) do
    with :ok <- exact_keys(event, @event_keys),
         :ok <- common(event),
         :ok <- identifier(event["epoch"]),
         true <- is_integer(event["cursor"]) and event["cursor"] > 0,
         true <- event["type"] in @event_types,
         :ok <- json_object(event["payload"]),
         :ok <- bounded(event, @max_event_bytes) do
      {:ok, event}
    else
      false -> {:error, :invalid_event}
      {:error, _reason} = error -> error
    end
  end

  def validate_event(_event), do: {:error, :invalid_event}

  def payload_digest(payload) do
    payload
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def canonical_json(map) when is_map(map) do
    members =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> [JSON.encode!(key), ":", canonical_json(value)] end)

    IO.iodata_to_binary(["{", Enum.intersperse(members, ","), "}"])
  end

  def canonical_json(list) when is_list(list),
    do: IO.iodata_to_binary(["[", Enum.intersperse(Enum.map(list, &canonical_json/1), ","), "]"])

  def canonical_json(value), do: JSON.encode!(value)

  @doc "Redacts structured secret keys and explicitly configured transient secrets before persistence."
  def redact_payload(payload, secrets \\ []) do
    payload
    |> redact(secrets)
    |> cap_payload()
  end

  defp common(%{"version" => 1, "workspace_id" => workspace, "operation_id" => operation}) do
    with :ok <- identifier(workspace), :ok <- identifier(operation), do: :ok
  end

  defp common(_message), do: {:error, :unsupported_version_or_identity}

  defp identifier(value) when is_binary(value) and byte_size(value) in 1..128 do
    case Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value) do
      true -> :ok
      false -> {:error, :invalid_identity}
    end
  end

  defp identifier(_value), do: {:error, :invalid_identity}

  defp exact_keys(map, keys) do
    case Enum.sort(Map.keys(map)) == Enum.sort(keys) do
      true -> :ok
      false -> {:error, :invalid_keys}
    end
  end

  defp json_object(map) when is_map(map) do
    case json_value?(map, 0) do
      true -> :ok
      false -> {:error, :invalid_json}
    end
  end

  defp json_object(_value), do: {:error, :invalid_payload}

  defp json_value?(_value, depth) when depth > 16, do: false

  defp json_value?(map, depth) when is_map(map),
    do: Enum.all?(map, fn {key, value} -> is_binary(key) and json_value?(value, depth + 1) end)

  defp json_value?(list, depth) when is_list(list),
    do: Enum.all?(list, &json_value?(&1, depth + 1))

  defp json_value?(value, _depth) when is_binary(value), do: String.valid?(value)

  defp json_value?(value, _depth),
    do: is_number(value) or is_boolean(value) or is_nil(value)

  defp digest_matches(command) do
    case command["payload_digest"] == payload_digest(command["payload"]) do
      true -> :ok
      false -> {:error, :payload_digest_mismatch}
    end
  end

  defp deadline_valid(deadline, options) do
    case Keyword.fetch(options, :now) do
      :error ->
        :ok

      {:ok, now} ->
        case DateTime.compare(deadline, now) do
          :gt -> :ok
          _expired -> {:error, :deadline_expired}
        end
    end
  end

  defp payload_shape("start", %{"prompt" => prompt} = payload)
       when is_binary(prompt) and byte_size(prompt) > 0 do
    case Map.fetch(payload, "provider_conversation_id") do
      :error ->
        exact_keys(payload, ["prompt"])

      {:ok, id} when is_binary(id) and byte_size(id) in 1..255 ->
        exact_keys(payload, ~w(prompt provider_conversation_id))

      {:ok, _invalid} ->
        {:error, :invalid_payload}
    end
  end

  defp payload_shape(type, payload) when type in ["inspect", "cancel"],
    do: exact_keys(payload, [])

  defp payload_shape("approve", %{"request_id" => id, "response" => response} = payload)
       when is_binary(id) and byte_size(id) in 1..255 and response in ["approved", "denied"],
       do: exact_keys(payload, ~w(request_id response))

  defp payload_shape(
         "read_events",
         %{"epoch" => epoch, "cursor" => cursor, "limit" => limit} = payload
       )
       when is_integer(cursor) and cursor >= 0 and is_integer(limit) and limit in 1..100 do
    with :ok <- exact_keys(payload, ~w(epoch cursor limit)), :ok <- identifier(epoch), do: :ok
  end

  defp payload_shape(_type, _payload), do: {:error, :invalid_payload}

  defp bounded(value, max_bytes) do
    case byte_size(JSON.encode!(value)) <= max_bytes do
      true -> :ok
      false -> {:error, :message_too_large}
    end
  end

  defp redact(map, secrets) when is_map(map) do
    Map.new(map, fn {key, value} ->
      value = if Regex.match?(@secret_key, key), do: "[REDACTED]", else: redact(value, secrets)
      {key, value}
    end)
  end

  defp redact(list, secrets) when is_list(list), do: Enum.map(list, &redact(&1, secrets))

  defp redact(value, secrets) when is_binary(value) do
    Enum.reduce(secrets, value, fn secret, text -> String.replace(text, secret, "[REDACTED]") end)
  end

  defp redact(value, _secrets), do: value

  defp cap_payload(payload) do
    case byte_size(JSON.encode!(payload)) <= 8_192 do
      true -> payload
      false -> %{"truncated" => true, "reason" => "event_payload_limit"}
    end
  end
end
