defmodule Hermitscale.WorkOS.EventsConsumer do
  @moduledoc """
  Single ordered Events API consumer guarded by a PostgreSQL advisory lock.
  """

  use Oban.Worker,
    queue: :workos,
    max_attempts: 20,
    unique: [
      period: 60,
      fields: [:worker],
      states: :incomplete
    ]

  alias Hermitscale.Repo

  alias Hermitscale.WorkOS.{
    Client,
    EventCursor,
    EventInbox,
    EventProcessor,
    StateReconciler
  }

  @stream "primary"
  @advisory_lock_key 1_216_405_507

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case drain_page() do
      {:ok, :caught_up} -> :ok
      {:ok, :more} -> {:snooze, 1}
      {:ok, :lock_busy} -> {:snooze, 2}
      {:ok, :reconciliation_scheduled} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Establishes a bounded time cursor after a successful full State API scan.

  The next Events API request uses `range_start`; once it receives an event,
  the ordinary event-ID cursor takes over.
  """
  def reset_from(%DateTime{} = range_start) do
    now = DateTime.utc_now(:second)

    %EventCursor{}
    |> EventCursor.changeset(%{
      stream: @stream,
      after_cursor: nil,
      range_start: range_start
    })
    |> Repo.insert(
      on_conflict: [
        set: [after_cursor: nil, range_start: range_start, updated_at: now]
      ],
      conflict_target: :stream
    )
  end

  @doc false
  def drain_page do
    Repo.transaction(fn ->
      case acquire_lock() do
        true -> fetch_and_apply_page()
        false -> :lock_busy
      end
    end)
    |> transaction_result()
  end

  defp fetch_and_apply_page do
    cursor =
      Repo.get(EventCursor, @stream) ||
        Repo.insert!(EventCursor.changeset(%EventCursor{}, %{stream: @stream}))

    opts =
      case {cursor.after_cursor, cursor.range_start} do
        {nil, %DateTime{} = range_start} -> [range_start: range_start]
        _cursor -> []
      end

    case client().list_events(cursor.after_cursor, EventProcessor.event_types(), opts) do
      {:ok, %{"data" => events} = response} when is_list(events) ->
        case events do
          [] ->
            :caught_up

          _events ->
            apply_nonempty_page(cursor, events, response)
        end

      {:ok, _invalid_body} ->
        {:client_error, :invalid_events_response}

      {:error, :unprocessable} ->
        case %{} |> StateReconciler.new() |> Oban.insert() do
          {:ok, _job} -> :reconciliation_scheduled
          {:error, reason} -> {:client_error, reason}
        end

      {:error, reason} ->
        {:client_error, reason}
    end
  end

  defp apply_nonempty_page(cursor, events, response) do
    with :ok <- apply_events(events),
         {:ok, next_cursor} <- page_cursor(events, response) do
      cursor
      |> EventCursor.changeset(%{
        after_cursor: next_cursor,
        range_start: nil
      })
      |> Repo.update!()

      :more
    else
      {:error, reason} -> {:projection_error, reason}
    end
  end

  defp page_cursor(events, response) do
    cursor =
      get_in(response, ["list_metadata", "after"]) ||
        events |> List.last() |> Map.get("id")

    case cursor do
      value when is_binary(value) and value != "" -> {:ok, value}
      _invalid -> {:error, :invalid_events_cursor}
    end
  end

  defp apply_events(events) do
    Enum.reduce_while(events, :ok, fn envelope, :ok ->
      with {:ok, event} <- EventInbox.insert_envelope(envelope),
           {:ok, _processed} <- EventInbox.process(event.event_id) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp acquire_lock do
    %{rows: [[locked?]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT pg_try_advisory_xact_lock($1)",
        [@advisory_lock_key]
      )

    locked?
  end

  defp transaction_result({:ok, :caught_up}), do: {:ok, :caught_up}
  defp transaction_result({:ok, :more}), do: {:ok, :more}
  defp transaction_result({:ok, :lock_busy}), do: {:ok, :lock_busy}

  defp transaction_result({:ok, :reconciliation_scheduled}),
    do: {:ok, :reconciliation_scheduled}

  defp transaction_result({:ok, {:projection_error, reason}}), do: {:error, reason}
  defp transaction_result({:ok, {:client_error, reason}}), do: {:error, reason}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp client do
    Application.get_env(:hermitscale, __MODULE__, [])[:client] || Client
  end
end
