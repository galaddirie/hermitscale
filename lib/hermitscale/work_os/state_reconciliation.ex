defmodule Hermitscale.WorkOS.StateReconciliation do
  @moduledoc """
  One generation of a full WorkOS State API reconciliation.

  A generation is marked complete only after every requested object family has
  been paginated successfully and missing-object detection has run.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "workos_state_reconciliations" do
    field :status, Ecto.Enum, values: [:running, :completed, :failed]
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :object_counts, :map, default: %{}
    field :error, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def start_changeset(reconciliation, attrs) do
    reconciliation
    |> cast(attrs, [:status, :started_at])
    |> validate_required([:status, :started_at])
    |> check_constraint(:status, name: :workos_state_reconciliations_status_check)
    |> unique_constraint(:status,
      name: :workos_state_reconciliations_one_running_index
    )
  end

  @doc false
  def complete_changeset(reconciliation, attrs) do
    reconciliation
    |> cast(attrs, [:status, :completed_at, :object_counts, :error])
    |> validate_required([:status, :completed_at, :object_counts])
    |> check_constraint(:status, name: :workos_state_reconciliations_status_check)
  end
end
