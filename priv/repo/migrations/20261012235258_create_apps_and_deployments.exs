defmodule Hermitscale.Repo.Migrations.CreateAppsAndDeployments do
  use Ecto.Migration

  def change do
    create table(:apps, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false
      add :created_by_user_id, :string, null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :repository, :string
      add :recipe, :string, null: false, default: "python-sqlite-v1"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:apps, [:org_id, :slug])
    create unique_index(:apps, [:id, :org_id])

    create table(:app_environments, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false

      add :app_id, references(:apps, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
        null: false

      add :workspace_id,
          references(:workspaces, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
          null: false

      add :name, :string, null: false
      add :configuration, :map, null: false, default: %{}
      add :configuration_digest, :string, null: false
      add :active_deployment_id, :uuid
      add :release_operation_id, :uuid
      add :status, :string, null: false, default: "sleeping"
      add :public, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:app_environments, [:app_id, :name])
    create unique_index(:app_environments, [:id, :org_id])
    create unique_index(:app_environments, [:workspace_id])

    create table(:app_build_sessions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false

      add :app_id, references(:apps, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
        null: false

      add :session_id,
          references(:agent_sessions, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
          null: false

      add :operation_key, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:app_build_sessions, [:app_id, :operation_key])
    create unique_index(:app_build_sessions, [:session_id])

    create table(:app_previews, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false

      add :app_id, references(:apps, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
        null: false

      add :session_id,
          references(:agent_sessions, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
          null: false

      add :workspace_id,
          references(:workspaces, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
          null: false

      add :lease_id, :uuid
      add :operation_key, :string, null: false
      add :source_commit, :string, null: false
      add :status, :string, null: false, default: "starting"
      add :verification, :map, null: false, default: %{}
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:app_previews, [:app_id, :operation_key])
    create unique_index(:app_previews, [:id, :org_id])

    create table(:app_deployments, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false

      add :app_id, references(:apps, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
        null: false

      add :environment_id,
          references(:app_environments,
            type: :uuid,
            with: [org_id: :org_id],
            on_delete: :restrict
          ),
          null: false

      add :session_id,
          references(:agent_sessions, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
          null: false

      add :execution_actor_user_id, :string, null: false
      add :operation_key, :string, null: false
      add :input_digest, :string, null: false
      add :target_digest, :string, null: false
      add :source_commit, :string, null: false
      add :recipe, :string, null: false
      add :artifact_id, :uuid
      add :artifact_digest, :string, null: false
      add :configuration_digest, :string, null: false
      add :expected_active_deployment_id, :uuid
      add :review_id, :uuid, null: false
      add :policy_revision, :integer, null: false, default: 1
      add :lease_id, :uuid
      add :status, :string, null: false, default: "queued"
      add :verification, :map, null: false, default: %{}
      add :error, :map, null: false, default: %{}
      add :backup_id, :uuid
      add :rollback_of_id, :uuid
      add :deadline, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:app_deployments, [:org_id, :operation_key])
    create unique_index(:app_deployments, [:id, :org_id])

    create table(:app_backups, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false

      add :environment_id,
          references(:app_environments,
            type: :uuid,
            with: [org_id: :org_id],
            on_delete: :restrict
          ),
          null: false

      add :artifact_id, :uuid, null: false
      add :digest, :string, null: false
      add :source_deployment_id, :uuid
      add :verification, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:app_backups, [:id, :org_id])

    create table(:app_access_grants, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false

      add :app_id, references(:apps, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
        null: false

      add :preview_id,
          references(:app_previews, type: :uuid, with: [org_id: :org_id], on_delete: :restrict)

      add :environment_id,
          references(:app_environments,
            type: :uuid,
            with: [org_id: :org_id],
            on_delete: :restrict
          )

      add :created_by_user_id, :string, null: false
      add :kind, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create table(:app_logs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false

      add :app_id, references(:apps, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
        null: false

      add :environment_id, :uuid
      add :deployment_id, :uuid
      add :kind, :string, null: false
      add :content, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:app_deployments, [:environment_id, :inserted_at])
    create index(:app_access_grants, [:app_id, :expires_at])
    create index(:app_logs, [:app_id, :inserted_at])
  end
end
