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

      timestamps(type: :utc_datetime)
    end

    create index(:sprite_workspaces, [:org_id, :inserted_at])
    create unique_index(:sprite_workspaces, [:sprite_name])
  end
end
