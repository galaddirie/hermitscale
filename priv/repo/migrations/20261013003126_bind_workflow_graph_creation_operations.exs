defmodule Hermitscale.Repo.Migrations.BindWorkflowGraphCreationOperations do
  use Ecto.Migration

  def change do
    alter table(:workflow_graphs) do
      add :operation_key, :string
      add :admission_digest, :string
    end

    create unique_index(:workflow_graphs, [:org_id, :created_by_user_id, :operation_key])

    create constraint(:workflow_graphs, :workflow_graph_operation_identity,
             check:
               "(operation_key IS NULL AND admission_digest IS NULL) OR (operation_key IS NOT NULL AND admission_digest IS NOT NULL AND octet_length(operation_key) BETWEEN 8 AND 128 AND admission_digest ~ '^[0-9a-f]{64}$')"
           )
  end
end
