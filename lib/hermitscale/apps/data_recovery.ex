defmodule Hermitscale.Apps.DataRecovery do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "app_data_recoveries" do
    field :org_id, :string
    field :environment_id, :binary_id
    field :backup_id, :binary_id
    field :execution_actor_user_id, :string
    field :operation_key, :string
    field :target_digest, :string
    field :review_id, :binary_id
    field :expected_active_deployment_id, :binary_id
    field :status, :string, default: "queued"
    field :deadline, :utc_datetime_usec
    field :lease_id, :binary_id
    field :verification, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :operation_key,
      :target_digest,
      :review_id,
      :expected_active_deployment_id,
      :deadline
    ])
    |> validate_required([
      :org_id,
      :environment_id,
      :backup_id,
      :execution_actor_user_id,
      :operation_key,
      :target_digest,
      :review_id,
      :deadline
    ])
    |> unique_constraint([:org_id, :operation_key])
  end
end
