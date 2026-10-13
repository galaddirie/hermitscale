defmodule Hermitscale.Apps.Deployment do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "app_deployments" do
    field :org_id, :string
    field :app_id, :binary_id
    field :environment_id, :binary_id
    field :session_id, :binary_id
    field :execution_actor_user_id, :string
    field :operation_key, :string
    field :input_digest, :string
    field :target_digest, :string
    field :source_commit, :string
    field :recipe, :string
    field :artifact_id, :binary_id
    field :artifact_digest, :string
    field :configuration_digest, :string
    field :expected_active_deployment_id, :binary_id
    field :lease_id, :binary_id
    field :status, :string, default: "queued"
    field :verification, :map, default: %{}
    field :error, :map, default: %{}
    field :backup_id, :binary_id
    field :rollback_of_id, :binary_id
    field :deadline, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :operation_key,
      :input_digest,
      :target_digest,
      :source_commit,
      :recipe,
      :artifact_id,
      :artifact_digest,
      :configuration_digest,
      :expected_active_deployment_id,
      :lease_id,
      :status,
      :verification,
      :error,
      :backup_id,
      :rollback_of_id,
      :deadline
    ])
    |> validate_required([
      :org_id,
      :app_id,
      :environment_id,
      :session_id,
      :execution_actor_user_id,
      :operation_key,
      :input_digest,
      :target_digest,
      :source_commit,
      :recipe,
      :artifact_digest,
      :configuration_digest,
      :status,
      :verification,
      :error,
      :deadline
    ])
    |> unique_constraint([:org_id, :operation_key])
  end
end
