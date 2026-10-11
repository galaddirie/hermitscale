defmodule Hermitscale.Repo.Migrations.AddWorkosReconciliationState do
  use Ecto.Migration

  def change do
    alter table(:workos_event_cursors) do
      add :range_start, :utc_datetime_usec
    end

    create table(:workos_state_reconciliations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :status, :string, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :object_counts, :map, null: false, default: %{}
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workos_state_reconciliations, [:started_at])

    create unique_index(:workos_state_reconciliations, [:status],
             where: "status = 'running'",
             name: :workos_state_reconciliations_one_running_index
           )

    create constraint(
             :workos_state_reconciliations,
             :workos_state_reconciliations_status_check,
             check: "status IN ('running', 'completed', 'failed')"
           )
  end
end
