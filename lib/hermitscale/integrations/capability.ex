defmodule Hermitscale.Integrations.Capability do
  @moduledoc "Hashed, expiring execution authority; never a stored bearer credential."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "execution_capabilities" do
    field :org_id, :string
    field :actor_user_id, :string
    field :token_digest, :string
    field :kind, :string
    field :resource_ids, {:array, :string}
    field :actions, {:array, :string}
    field :operation_id, :string
    field :connection, :map, default: %{}
    field :models, {:array, :string}, default: []
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :remaining_calls, :integer
    field :remaining_cost_micros, :integer
    field :initial_cost_micros, :integer, default: 0
    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :kind,
      :resource_ids,
      :actions,
      :operation_id,
      :connection,
      :models,
      :remaining_calls,
      :remaining_cost_micros
    ])
    |> validate_required([
      :org_id,
      :actor_user_id,
      :token_digest,
      :kind,
      :expires_at,
      :resource_ids,
      :actions,
      :remaining_calls,
      :remaining_cost_micros
    ])
    |> validate_inclusion(:kind, ["inference", "product"])
    |> validate_number(:remaining_calls, greater_than: 0, less_than_or_equal_to: 1000)
    |> validate_number(:remaining_cost_micros, greater_than_or_equal_to: 0)
    |> unique_constraint(:token_digest)
  end
end
