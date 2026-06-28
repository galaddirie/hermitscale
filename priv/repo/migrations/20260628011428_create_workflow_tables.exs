defmodule Hermitscale.Repo.Migrations.CreateWorkflowTables do
  use Ecto.Migration

  def change do
    create table(:workflow_graphs, primary_key: false) do
      add :id, :string, primary_key: true
      add :schema_version, :integer, null: false, default: 1
      add :name, :string, null: false
      add :definition, :map, null: false
      add :status, :string, null: false, default: "draft"
      add :validation_issues, {:array, :map}, null: false, default: []
      add :validated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:workflow_graphs, [:status])
    create index(:workflow_graphs, [:name])

    create table(:workflow_runs, primary_key: false) do
      add :id, :string, primary_key: true
      add :workflow_graph_id, references(:workflow_graphs, type: :string, on_delete: :nilify_all)
      add :status, :string, null: false, default: "created"
      add :owner, :string
      add :lease_expires_at, :utc_datetime
      add :last_event_sequence, :integer, null: false, default: 0
      add :input, :map
      add :output, :map
      add :error, :map
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:workflow_runs, [:workflow_graph_id])
    create index(:workflow_runs, [:status])
    create index(:workflow_runs, [:owner, :lease_expires_at])

    create table(:workflow_run_events) do
      add :run_id, references(:workflow_runs, type: :string, on_delete: :delete_all), null: false
      add :sequence, :integer, null: false
      add :event, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:workflow_run_events, [:run_id])
    create unique_index(:workflow_run_events, [:run_id, :sequence])
  end
end
