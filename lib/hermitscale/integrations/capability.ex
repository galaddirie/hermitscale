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
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :remaining_calls, :integer
    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :kind,
      :resource_ids,
      :actions,
      :remaining_calls
    ])
    |> validate_required([
      :org_id,
      :actor_user_id,
      :token_digest,
      :kind,
      :expires_at,
      :resource_ids,
      :actions,
      :remaining_calls
    ])
    |> validate_inclusion(:kind, ["product"])
    |> validate_number(:remaining_calls, greater_than: 0, less_than_or_equal_to: 1000)
    |> unique_constraint(:token_digest)
  end
end
