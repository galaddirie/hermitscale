defmodule Hermitscale.WorkOS.EventRetentionWorker do
  @moduledoc """
  Redacts PII-bearing WorkOS event bodies after successful projection.

  Event identity, type, timestamps, and terminal classification remain for
  deduplication and operational audit. Failed events retain their payload so
  an operator can diagnose and replay them.
  """

  use Oban.Worker,
    queue: :workos,
    max_attempts: 5,
    unique: [
      period: 23 * 60 * 60,
      fields: [:worker],
      states: :incomplete
    ]

  import Ecto.Query

  alias Hermitscale.Repo
  alias Hermitscale.WorkOS.Event

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    retention_hours =
      Application.get_env(:hermitscale, __MODULE__, [])
      |> Keyword.get(:raw_event_retention_hours, 24)

    cutoff =
      DateTime.utc_now(:second)
      |> DateTime.add(-retention_hours, :hour)

    {count, _rows} =
      from(event in Event,
        where:
          event.status in [:processed, :ignored] and
            event.processed_at < ^cutoff and
            fragment("?->>'redacted' IS DISTINCT FROM 'true'", event.payload),
        update: [
          set: [
            payload:
              fragment(
                "jsonb_build_object('id', ?, 'event', ?, 'redacted', true)",
                event.event_id,
                event.event_type
              )
          ]
        ]
      )
      |> Repo.update_all([])

    :telemetry.execute(
      [:hermitscale, :workos, :event, :redacted],
      %{count: count},
      %{}
    )

    :ok
  end
end
