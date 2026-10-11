defmodule Hermitscale.WorkOS.EventCursor do
  @moduledoc """
  Persisted WorkOS Events API cursor.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:stream, :string, autogenerate: false}

  schema "workos_event_cursors" do
    field :after_cursor, :string
    field :range_start, :utc_datetime_usec

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, [:stream, :after_cursor, :range_start])
    |> validate_required([:stream])
  end
end
