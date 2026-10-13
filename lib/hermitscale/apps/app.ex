defmodule Hermitscale.Apps.App do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "apps" do
    field :org_id, :string
    field :created_by_user_id, :string
    field :name, :string
    field :slug, :string
    field :repository, :string
    field :recipe, :string, default: "python-sqlite-v1"
    field :operation_key, :string, virtual: true
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:name, :slug, :repository, :recipe, :operation_key])
    |> validate_required([:org_id, :created_by_user_id, :name, :slug, :recipe])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 160)
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
    |> validate_length(:slug, max: 80)
    |> validate_format(:repository, ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)
    |> validate_inclusion(:recipe, ["python-sqlite-v1"])
    |> unique_constraint([:org_id, :slug])
  end
end
