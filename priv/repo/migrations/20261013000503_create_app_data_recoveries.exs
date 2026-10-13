defmodule Hermitscale.Repo.Migrations.CreateAppDataRecoveries do
  use Ecto.Migration

  def change do
    create table(:app_data_recoveries, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false

      add :environment_id,
          references(:app_environments,
            type: :uuid,
            with: [org_id: :org_id],
            on_delete: :restrict
          ),
          null: false

      add :backup_id,
          references(:app_backups, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
          null: false

      add :execution_actor_user_id, :string, null: false
      add :operation_key, :string, null: false
      add :target_digest, :string, null: false
      add :review_id, :uuid, null: false
      add :expected_active_deployment_id, :uuid
      add :status, :string, null: false, default: "queued"
      add :deadline, :utc_datetime_usec, null: false
      add :lease_id, :uuid
      add :verification, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:app_data_recoveries, [:org_id, :operation_key])
  end
end
