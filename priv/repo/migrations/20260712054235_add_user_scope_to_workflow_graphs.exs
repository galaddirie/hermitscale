defmodule Hermitscale.Repo.Migrations.AddUserScopeToWorkflowGraphs do
  use Ecto.Migration

  def change do
    alter table(:workflow_graphs) do
      add :user_id, references(:users, on_delete: :delete_all)
    end

    create index(:workflow_graphs, [:user_id])
  end
end
