defmodule Hermitscale.Artifacts.Artifact do
  @moduledoc "Private bounded exported evidence with a content digest."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "artifacts" do
    field :org_id, :string
    field :created_by_user_id, :string
    field :owner_type, :string
    field :owner_id, :string
    field :kind, :string
    field :digest, :string
    field :content_type, :string
    field :size_bytes, :integer
    field :content, :binary
    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:owner_type, :owner_id, :kind, :content_type])
    |> validate_required([
      :org_id,
      :created_by_user_id,
      :owner_type,
      :owner_id,
      :kind,
      :digest,
      :content_type,
      :size_bytes
    ])
    |> validate_number(:size_bytes, greater_than_or_equal_to: 0, less_than_or_equal_to: 8_388_608)
    |> unique_constraint([:org_id, :owner_type, :owner_id, :kind, :digest])
  end
end
