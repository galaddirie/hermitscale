defmodule Hermitscale.Triggers.WebhookSubscription do
  @moduledoc "Durable desired and acknowledged provider webhook state; signing keys are derived at runtime."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "provider_webhook_subscriptions" do
    belongs_to :trigger, Hermitscale.Triggers.Trigger, type: :string
    field :provider, :string
    field :webhook_token, :string
    field :desired_config, :map, default: %{}
    field :remote_config, :map, default: %{}
    field :retired_configs, :map, default: %{}
    field :remote_id, :string
    field :enabled, :boolean, default: true
    field :status, Ecto.Enum, values: [:pending, :active, :inactive, :errored], default: :pending
    field :error, :map
    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :trigger_id,
      :provider,
      :webhook_token,
      :desired_config,
      :remote_config,
      :retired_configs,
      :remote_id,
      :enabled,
      :status,
      :error
    ])
    |> validate_required([:provider, :webhook_token, :desired_config, :status])
    |> validate_inclusion(:provider, ~w(github linear))
    |> unique_constraint(:trigger_id)
    |> unique_constraint(:webhook_token)
    |> foreign_key_constraint(:trigger_id)
    |> check_constraint(:provider, name: :provider_webhook_provider)
  end
end
