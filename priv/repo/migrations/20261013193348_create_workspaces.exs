defmodule Hermitscale.Repo.Migrations.CreateWorkspaces do
  use Ecto.Migration

  def change do
    create table(:sprite_workspaces, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, :string, null: false
      add :created_by_user_id, :string, null: false
      add :name, :string, null: false
      add :description, :text
      add :sprite_name, :string, null: false
      add :status, :string, null: false, default: "provisioning"
      add :sprite_data, :map, null: false, default: %{}
      add :last_error, :map
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:sprite_workspaces, [:org_id, :inserted_at])
    create unique_index(:sprite_workspaces, [:sprite_name])

    create constraint(:sprite_workspaces, :sprite_workspaces_status,
             check: "status IN ('provisioning', 'ready', 'failed', 'deleting')"
           )
  end
end
