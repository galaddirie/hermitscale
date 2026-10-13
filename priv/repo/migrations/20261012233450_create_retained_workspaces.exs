defmodule Hermitscale.Repo.Migrations.CreateRetainedWorkspaces do
  use Ecto.Migration

  def change do
    create table(:workspaces, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false
      add :created_by_user_id, :string, null: false
      add :owner_key, :string, null: false
      add :sprite_name, :string, null: false
      add :recipe, :string, null: false
      add :repository, :text
      add :base_sha, :string
      add :resource_state, :string, null: false, default: "provision_pending"
      add :compute_state, :string, null: false, default: "unknown"
      add :generation, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspaces, [:org_id, :owner_key])
    create unique_index(:workspaces, [:sprite_name])
    create unique_index(:workspaces, [:id, :org_id])

    create constraint(:workspaces, :workspaces_resource_state_check,
             check: "resource_state IN ('provision_pending', 'retained', 'deleting', 'deleted')"
           )

    create constraint(:workspaces, :workspaces_compute_state_check,
             check: "compute_state IN ('unknown', 'sleeping', 'running')"
           )

    create constraint(:workspaces, :workspaces_generation_check, check: "generation >= 0")

    create table(:workspace_leases, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false

      add :workspace_id,
          references(:workspaces, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
          null: false

      add :execution_actor_user_id, :string, null: false
      add :operation_key, :string, null: false
      add :generation, :bigint, null: false
      add :deadline, :utc_datetime_usec, null: false
      add :status, :string, null: false, default: "active"
      add :termination_evidence, :map, null: false, default: %{}
      add :released_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspace_leases, [:workspace_id, :operation_key])

    create unique_index(:workspace_leases, [:workspace_id],
             where: "status = 'active'",
             name: :workspace_leases_one_active_writer
           )

    create unique_index(:workspace_leases, [:id, :org_id])
    create index(:workspace_leases, [:org_id, :deadline])

    create constraint(:workspace_leases, :workspace_leases_status_check,
             check: "status IN ('active', 'released')"
           )

    create constraint(:workspace_leases, :workspace_leases_generation_check,
             check: "generation > 0"
           )

    create constraint(:workspace_leases, :workspace_leases_release_check,
             check:
               "(status = 'active' AND released_at IS NULL) OR (status = 'released' AND released_at IS NOT NULL)"
           )

    create table(:workspace_protections, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false

      add :workspace_id,
          references(:workspaces, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
          null: false

      add :owner_key, :string, null: false
      add :reason, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspace_protections, [:workspace_id, :owner_key])
    create index(:workspace_protections, [:org_id])
  end
end
