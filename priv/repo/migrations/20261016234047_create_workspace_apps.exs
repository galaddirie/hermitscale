defmodule Hermitscale.Repo.Migrations.CreateWorkspaceApps do
  use Ecto.Migration

  def change do
    create table(:workspace_apps, primary_key: false) do
      add :id, :string, primary_key: true

      add :workspace_id, references(:sprite_workspaces, type: :string, on_delete: :delete_all),
        null: false

      add :org_id, :string, null: false
      add :slug, :string, null: false
      add :access, :string, null: false
      add :sprite_url, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_apps, [:workspace_id])
    create unique_index(:workspace_apps, [:slug])
    create index(:workspace_apps, [:org_id])

    create constraint(:workspace_apps, :access_must_be_known,
             check: "access IN ('org', 'public')"
           )
  end
end
