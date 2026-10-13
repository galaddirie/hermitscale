defmodule Hermitscale.Support.Subscription do
  @moduledoc "Trusted organization/app/environment ticket mapping; customer prose cannot change it."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "support_subscriptions" do
    field :org_id, :string
    field :created_by_user_id, :string
    field :app_id, :binary_id
    field :environment_id, :binary_id
    field :connection, :map
    field :connection_set, :map, default: %{}
    field :ticket_prefix, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs),
    do:
      record
      |> cast(attrs, [:connection, :connection_set, :ticket_prefix])
      |> validate_format(:ticket_prefix, ~r/\A[A-Z][A-Z0-9_]{0,30}-\z/)
      |> validate_required([
        :org_id,
        :created_by_user_id,
        :app_id,
        :environment_id,
        :connection,
        :ticket_prefix
      ])
end
