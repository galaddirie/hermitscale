defmodule Hermitscale.Repo.Migrations.RetainRetiredWebhookRegistrationConfigs do
  use Ecto.Migration

  def change do
    alter table(:provider_webhook_subscriptions) do
      add :retired_configs, :map, null: false, default: %{}
    end
  end
end
