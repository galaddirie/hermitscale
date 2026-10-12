defmodule Hermitscale.Repo.Migrations.CreateProviderWebhookSubscriptions do
  use Ecto.Migration

  def change do
    create table(:provider_webhook_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :trigger_id, references(:workflow_triggers, type: :string, on_delete: :nilify_all)
      add :provider, :string, null: false
      add :webhook_token, :string, null: false
      add :desired_config, :map, null: false, default: %{}
      add :remote_config, :map, null: false, default: %{}
      add :remote_id, :string
      add :enabled, :boolean, null: false, default: true
      add :status, :string, null: false, default: "pending"
      add :error, :map
      timestamps(type: :utc_datetime)
    end

    create unique_index(:provider_webhook_subscriptions, [:trigger_id])
    create unique_index(:provider_webhook_subscriptions, [:webhook_token])
    create index(:provider_webhook_subscriptions, [:status])

    create constraint(:provider_webhook_subscriptions, :provider_webhook_provider,
             check: "provider IN ('github', 'linear')"
           )

    create table(:provider_webhook_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :subscription_id, references(:provider_webhook_subscriptions, type: :binary_id),
        null: false

      add :delivery_key, :string, null: false
      add :registration_id, :string, null: false
      add :payload, :map, null: false
      add :status, :string, null: false, default: "pending"
      add :error, :map
      add :run_id, references(:workflow_runs, type: :string, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:provider_webhook_deliveries, [:subscription_id, :delivery_key])
    create index(:provider_webhook_deliveries, [:run_id])
  end
end
