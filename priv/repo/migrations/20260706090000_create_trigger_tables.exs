defmodule Hermitscale.Repo.Migrations.CreateTriggerTables do
  use Ecto.Migration

  def change do
    create table(:workflow_triggers, primary_key: false) do
      add :id, :string, primary_key: true

      add :workflow_graph_id,
          references(:workflow_graphs, type: :string, on_delete: :delete_all),
          null: false

      add :node_id, :string, null: false
      add :type, :string, null: false
      add :version, :integer, null: false
      add :mode, :string, null: false
      add :config, :map, null: false, default: %{}
      add :webhook_token, :string
      add :schedule, :string
      add :next_fire_at, :utc_datetime
      add :cursor, :map
      add :status, :string, null: false, default: "enabled"
      add :error, :map

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workflow_triggers, [:workflow_graph_id, :node_id])
    create unique_index(:workflow_triggers, [:webhook_token])
    create index(:workflow_triggers, [:mode, :status])
    create index(:workflow_triggers, [:mode, :status, :next_fire_at])

    create table(:workflow_trigger_firings) do
      add :trigger_id,
          references(:workflow_triggers, type: :string, on_delete: :delete_all),
          null: false

      add :run_id, references(:workflow_runs, type: :string, on_delete: :nilify_all)
      add :idempotency_key, :string, null: false
      add :outcome, :string, null: false, default: "dispatched"
      add :error, :map
      add :fired_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workflow_trigger_firings, [:trigger_id, :idempotency_key])
    create index(:workflow_trigger_firings, [:run_id])
  end
end
