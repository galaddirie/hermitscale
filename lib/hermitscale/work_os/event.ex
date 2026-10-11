defmodule Hermitscale.WorkOS.Event do
  @moduledoc """
  Idempotent inbox row for a WorkOS event envelope.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:event_id, :string, autogenerate: false}

  schema "workos_events" do
    field :event_type, :string
    field :payload, :map
    field :occurred_at, :utc_datetime_usec
    field :status, Ecto.Enum, values: [:pending, :processed, :ignored, :failed], default: :pending
    field :processed_at, :utc_datetime
    field :processing_error, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def receipt_changeset(event, attrs) do
    event
    |> cast(attrs, [:event_id, :event_type, :payload, :occurred_at])
    |> validate_required([:event_id, :event_type, :payload, :occurred_at])
    |> validate_length(:event_id, max: 255)
    |> validate_length(:event_type, max: 255)
    |> unique_constraint(:event_id)
  end

  @doc false
  def processed_changeset(event, status, processing_error \\ nil)
      when status in [:processed, :ignored, :failed] do
    change(event,
      status: status,
      processed_at: DateTime.utc_now(:second),
      processing_error: processing_error
    )
  end
end
