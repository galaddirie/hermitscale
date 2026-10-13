defmodule Hermitscale.Integrations.Delivery do
  @moduledoc "One provider mutation intent and its known or uncertain remote outcome."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}

  schema "integration_deliveries" do
    field :org_id, :string
    field :actor_user_id, :string
    field :effect_key, :string
    field :provider, :string
    field :payload_digest, :string
    field :status, Ecto.Enum, values: [:pending, :uncertain, :succeeded], default: :pending
    field :result, :map
    timestamps(type: :utc_datetime)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:effect_key, :provider, :payload_digest, :status, :result])
    |> validate_required([
      :org_id,
      :actor_user_id,
      :effect_key,
      :provider,
      :payload_digest,
      :status
    ])
    |> validate_length(:effect_key, min: 8, max: 128)
    |> validate_inclusion(:provider, ["github", "linear"])
    |> unique_constraint([:org_id, :effect_key])
  end
end
