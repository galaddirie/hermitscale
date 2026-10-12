defmodule Hermitscale.Repo.Migrations.AddExecutionIdentityAndAccountSelections do
  use Ecto.Migration

  def change do
    alter table(:workflow_triggers) do
      add :execution_actor_user_id, :string
    end

    alter table(:workflow_runs) do
      add :initiated_by_user_id, :string
      add :execution_actor_user_id, :string
      add :trigger_id, references(:workflow_triggers, type: :string, on_delete: :nilify_all)
      add :account_selections, :map, null: false, default: %{}
    end

    create index(:workflow_runs, [:trigger_id])
    create index(:workflow_triggers, [:execution_actor_user_id])
  end
end
