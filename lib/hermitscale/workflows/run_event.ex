defmodule Hermitscale.Workflows.RunEvent do
  @moduledoc """
  Append-only serialized Runic event for a workflow run.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :string

  schema "workflow_run_events" do
    field :sequence, :integer
    field :event, :binary

    belongs_to :run, Hermitscale.Workflows.Run

    timestamps(type: :utc_datetime)
  end

  def changeset(run_event, attrs) do
    run_event
    |> cast(attrs, [:run_id, :sequence, :event])
    |> validate_required([:run_id, :sequence, :event])
    |> validate_number(:sequence, greater_than: 0)
    |> foreign_key_constraint(:run_id)
    |> unique_constraint([:run_id, :sequence])
  end
end
