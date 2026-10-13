defmodule Hermitscale.Repo.Migrations.CreateWorkflowExternalOperations do
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      add :definition, :map
    end

    create table(:workflow_external_operations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :run_id, references(:workflow_runs, type: :string, on_delete: :delete_all), null: false
      add :org_id, :string, null: false
      add :actor_user_id, :string, null: false
      add :node_id, :string, null: false
      add :node_type, :string, null: false
      add :definition_identity, :string, null: false
      add :node_identity, :string, null: false
      add :input_identity, :string, null: false
      add :activation_identity, :string, null: false
      add :lineage, :map, null: false
      add :request, :map, null: false
      add :status, :string, null: false, default: "admitted"
      add :resource, :map, null: false, default: %{}
      add :result, :map
      add :error, :map
      add :outcome_digest, :string
      add :deadline, :utc_datetime, null: false
      add :completed_at, :utc_datetime
      add :consumed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:workflow_external_operations, [:run_id, :activation_identity])
    create index(:workflow_external_operations, [:run_id, :status])
    create index(:workflow_external_operations, [:org_id, :actor_user_id])
    create index(:workflow_external_operations, [:status, :deadline])

    create constraint(:workflow_external_operations, :workflow_external_operations_status_check,
             check: "status IN ('admitted', 'waiting', 'terminal', 'consumed')"
           )

    create constraint(:workflow_external_operations, :workflow_external_operations_outcome_check,
             check:
               "(status IN ('admitted', 'waiting') AND outcome_digest IS NULL AND completed_at IS NULL AND consumed_at IS NULL) OR (status = 'terminal' AND outcome_digest IS NOT NULL AND completed_at IS NOT NULL AND consumed_at IS NULL) OR (status = 'consumed' AND outcome_digest IS NOT NULL AND completed_at IS NOT NULL AND consumed_at IS NOT NULL)"
           )
  end
end
