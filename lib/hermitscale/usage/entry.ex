defmodule Hermitscale.Usage.Entry do
  @moduledoc "Deduplicated measured model, compute, or storage usage."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "usage_entries" do
    field :org_id, :string
    field :operation_id, :string
    field :category, Ecto.Enum, values: [:compute, :storage, :model]
    field :deduplication_key, :string
    field :quantity, :integer
    field :cost_micros, :integer
    field :rate_version, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :operation_id,
      :category,
      :deduplication_key,
      :quantity,
      :cost_micros,
      :rate_version
    ])
    |> validate_required([
      :org_id,
      :operation_id,
      :category,
      :deduplication_key,
      :quantity,
      :cost_micros,
      :rate_version
    ])
    |> validate_number(:quantity, greater_than_or_equal_to: 0)
    |> validate_number(:cost_micros, greater_than_or_equal_to: 0)
    |> unique_constraint([:org_id, :deduplication_key])
  end
end
