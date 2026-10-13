defmodule Hermitscale.Repo.Migrations.BindAgentSessionsToSourceBundles do
  use Ecto.Migration

  def change do
    alter table(:agent_sessions) do
      add :source_bundle, :map, null: false, default: %{}
    end
  end
end
