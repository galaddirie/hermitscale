defmodule Hermitscale.Triggers.WebhookDelivery do
  @moduledoc "An authenticated provider event retained before HTTP acknowledgement."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "provider_webhook_deliveries" do
    belongs_to :subscription, Hermitscale.Triggers.WebhookSubscription
    belongs_to :run, Hermitscale.Workflows.Run, type: :string
    field :delivery_key, :string
    field :registration_id, :string
    field :payload, :map

    field :status, Ecto.Enum,
      values: [:pending, :dispatched, :ignored, :failed],
      default: :pending

    field :error, :map
    timestamps(type: :utc_datetime)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :subscription_id,
      :delivery_key,
      :registration_id,
      :payload,
      :status,
      :run_id,
      :error
    ])
    |> validate_required([:subscription_id, :delivery_key, :registration_id, :payload, :status])
    |> validate_length(:delivery_key, max: 256)
    |> unique_constraint([:subscription_id, :delivery_key])
    |> foreign_key_constraint(:subscription_id)
    |> foreign_key_constraint(:run_id)
  end
end
