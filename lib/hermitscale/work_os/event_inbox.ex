defmodule Hermitscale.WorkOS.EventInbox do
  @moduledoc """
  Authenticates WorkOS webhook notifications and owns the idempotent event inbox.
  """

  alias Hermitscale.Repo

  alias Hermitscale.WorkOS.{
    Event,
    EventProcessor,
    EventsConsumer,
    WebhookSignature
  }

  @doc """
  Verifies and stores a raw WorkOS webhook body, then wakes the ordered consumer.
  """
  def receive_webhook(endpoint_token, signature_header, raw_body)
      when is_binary(endpoint_token) and is_binary(raw_body) do
    config = config()

    with :ok <- verify_endpoint_token(endpoint_token, config[:endpoint_token]),
         :ok <-
           WebhookSignature.verify(
             raw_body,
             signature_header,
             config[:secrets] || [],
             tolerance_seconds: config[:tolerance_seconds] || 300
           ),
         {:ok, envelope} <- Jason.decode(raw_body),
         {:ok, event} <- insert_envelope(envelope),
         {:ok, _job} <- wake_consumer() do
      :telemetry.execute(
        [:hermitscale, :workos, :event, :received],
        %{count: 1},
        %{event_type: event.event_type}
      )

      {:ok, event}
    end
  end

  @doc """
  Inserts an event envelope once and returns the stored row.
  """
  def insert_envelope(envelope) when is_map(envelope) do
    with {:ok, attrs} <- envelope_attrs(envelope) do
      changeset = Event.receipt_changeset(%Event{}, attrs)

      case Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: :event_id,
             returning: true
           ) do
        {:ok, %Event{}} ->
          attrs.event_id
          |> then(&Repo.get!(Event, &1))
          |> classify_unsupported()

        {:error, _changeset} = error ->
          error
      end
    end
  end

  @doc """
  Applies one inbox row idempotently, persisting its terminal classification.
  """
  def process(event_id) when is_binary(event_id) do
    case Repo.get(Event, event_id) do
      %Event{status: status} = event when status in [:processed, :ignored] ->
        {:ok, event}

      %Event{} = event ->
        process_pending(event)

      nil ->
        {:error, :event_not_found}
    end
  end

  defp process_pending(event) do
    case EventProcessor.apply(event.payload) do
      :ok ->
        result =
          event
          |> Event.processed_changeset(:processed)
          |> Repo.update()

        emit_processed(event, :processed)
        result

      {:ignored, reason} ->
        result =
          event
          |> Event.processed_changeset(:ignored, inspect(reason))
          |> Repo.update()

        emit_processed(event, :ignored)
        result

      {:error, reason} ->
        _result =
          event
          |> Event.processed_changeset(:failed, truncate_error(reason))
          |> Repo.update()

        emit_processed(event, :failed)
        {:error, reason}
    end
  end

  defp envelope_attrs(envelope) do
    with {:ok, event_id} <- required_string(envelope, "id"),
         {:ok, event_type} <- required_string(envelope, "event"),
         {:ok, occurred_at} <- parse_timestamp(envelope["created_at"]) do
      {:ok,
       %{
         event_id: event_id,
         event_type: event_type,
         payload: envelope,
         occurred_at: occurred_at
       }}
    end
  end

  defp parse_timestamp(%DateTime{} = timestamp), do: {:ok, timestamp}

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      {:error, _reason} -> {:error, :invalid_event_timestamp}
    end
  end

  defp parse_timestamp(timestamp) when is_integer(timestamp) do
    timestamp = if timestamp > 10_000_000_000, do: div(timestamp, 1_000), else: timestamp
    DateTime.from_unix(timestamp)
  end

  defp parse_timestamp(_timestamp), do: {:error, :invalid_event_timestamp}

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:invalid_event_envelope, key}}
    end
  end

  defp verify_endpoint_token(provided, expected)
       when is_binary(expected) and byte_size(provided) == byte_size(expected) do
    case Plug.Crypto.secure_compare(provided, expected) do
      true -> :ok
      false -> {:error, :invalid_endpoint_token}
    end
  end

  defp verify_endpoint_token(_provided, _expected), do: {:error, :invalid_endpoint_token}

  defp wake_consumer do
    %{}
    |> EventsConsumer.new()
    |> Oban.insert()
  end

  defp truncate_error(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 1_000)
    |> String.slice(0, 2_000)
  end

  defp config do
    Application.get_env(:hermitscale, __MODULE__, [])
  end

  defp classify_unsupported(%Event{status: :pending} = event) do
    case event.event_type in EventProcessor.event_types() do
      true ->
        {:ok, event}

      false ->
        result =
          event
          |> Event.processed_changeset(:ignored, "unsupported_event_type")
          |> Repo.update()

        emit_processed(event, :ignored)
        result
    end
  end

  defp classify_unsupported(%Event{} = event), do: {:ok, event}

  defp emit_processed(event, status) do
    :telemetry.execute(
      [:hermitscale, :workos, :event, :processed],
      %{count: 1},
      %{event_type: event.event_type, status: status}
    )
  end
end
