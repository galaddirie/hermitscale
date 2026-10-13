defmodule Hermitscale.Workflows.ExternalOperation do
  @moduledoc "Durable effect intent tied to an exact Runic definition and input occurrence."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  schema "workflow_external_operations" do
    belongs_to :run, Hermitscale.Workflows.Run
    field :org_id, :string
    field :actor_user_id, :string
    field :node_id, :string
    field :node_type, :string
    field :definition_identity, :string
    field :node_identity, :string
    field :input_identity, :string
    field :activation_identity, :string
    field :lineage, :map
    field :request, :map

    field :status, Ecto.Enum,
      values: [:admitted, :waiting, :terminal, :consumed],
      default: :admitted

    field :resource, :map, default: %{}
    field :result, :map
    field :error, :map
    field :outcome_digest, :string
    field :deadline, :utc_datetime
    field :completed_at, :utc_datetime
    field :consumed_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :status,
      :resource,
      :result,
      :error,
      :outcome_digest,
      :completed_at,
      :consumed_at
    ])
    |> validate_required([
      :run_id,
      :org_id,
      :actor_user_id,
      :node_id,
      :node_type,
      :definition_identity,
      :node_identity,
      :input_identity,
      :activation_identity,
      :lineage,
      :request,
      :deadline,
      :status
    ])
    |> unique_constraint([:run_id, :activation_identity])
    |> foreign_key_constraint(:run_id)
    |> check_constraint(:status, name: :workflow_external_operations_status_check)
    |> check_constraint(:status, name: :workflow_external_operations_outcome_check)
  end
end
