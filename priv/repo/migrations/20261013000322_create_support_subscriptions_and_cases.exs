defmodule Hermitscale.Repo.Migrations.CreateSupportSubscriptionsAndCases do
  use Ecto.Migration

  def change do
    create table(:support_subscriptions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false
      add :created_by_user_id, :string, null: false
      add :app_id, :uuid, null: false
      add :environment_id, :uuid, null: false
      add :connection, :map, null: false
      add :ticket_prefix, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:support_subscriptions, [:org_id, :app_id])
    create unique_index(:support_subscriptions, [:id, :org_id])

    create table(:support_cases, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false

      add :subscription_id,
          references(:support_subscriptions, type: :uuid, with: [org_id: :org_id]),
          null: false

      add :initiator_user_id, :string, null: false
      add :operation_key, :string, null: false
      add :ticket_id, :string, null: false

      add :session_id, references(:agent_sessions, type: :uuid, with: [org_id: :org_id]),
        null: false

      add :deployed_revision, :string
      add :reply, :map
      timestamps(type: :utc_datetime)
    end

    create unique_index(:support_cases, [:org_id, :operation_key])
  end
end
