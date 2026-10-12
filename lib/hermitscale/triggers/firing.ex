defmodule Hermitscale.Triggers.Firing do
  @moduledoc """
  Audit record for one trigger firing attempt.

  The `{trigger_id, idempotency_key}` unique index is the dedupe mechanism for
  webhook redeliveries, overlapping polls, and scheduler restarts. Completed
  attempts dedupe; failed attempts may retry. A dispatched row without its run
  link remains unresolved rather than being reported as successfully handled.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :string

  schema "workflow_trigger_firings" do
    field :idempotency_key, :string
    field :outcome, Ecto.Enum, values: [:dispatched, :rejected, :failed], default: :dispatched
    field :error, :map
    field :fired_at, :utc_datetime

    belongs_to :trigger, Hermitscale.Triggers.Trigger
    belongs_to :run, Hermitscale.Workflows.Run

    timestamps(type: :utc_datetime)
  end

  def changeset(firing, attrs) do
    firing
    |> cast(attrs, [:trigger_id, :run_id, :idempotency_key, :outcome, :error, :fired_at])
    |> validate_required([:trigger_id, :idempotency_key, :outcome, :fired_at])
    |> unique_constraint([:trigger_id, :idempotency_key])
  end
end
