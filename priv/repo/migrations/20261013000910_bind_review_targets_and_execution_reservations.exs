defmodule Hermitscale.Repo.Migrations.BindReviewTargetsAndExecutionReservations do
  use Ecto.Migration

  def change do
    alter table(:reviews) do
      add :target, :map, null: false, default: %{}
    end

    alter table(:execution_capabilities) do
      add :initial_cost_micros, :bigint, null: false, default: 0
    end

    create constraint(:execution_capabilities, :execution_capabilities_budget,
             check:
               "remaining_cost_micros >= 0 AND initial_cost_micros >= 0 AND remaining_calls >= 0"
           )
  end
end
