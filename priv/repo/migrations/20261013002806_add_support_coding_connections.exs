defmodule Hermitscale.Repo.Migrations.AddSupportCodingConnections do
  use Ecto.Migration

  def change do
    alter table(:support_subscriptions) do
      add :connection_set, :map, null: false, default: %{}
    end
  end
end
