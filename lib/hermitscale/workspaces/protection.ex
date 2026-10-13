defmodule Hermitscale.Workspaces.Protection do
  @moduledoc "Retention protection that never wakes compute."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "workspace_protections" do
    field :org_id, :string
    belongs_to :workspace, Hermitscale.Workspaces.Workspace
    field :owner_key, :string
    field :reason, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(protection, attrs) do
    protection
    |> cast(attrs, [:owner_key, :reason])
    |> validate_required([:workspace_id, :org_id, :owner_key, :reason])
    |> validate_length(:owner_key, min: 1, max: 255)
    |> validate_length(:reason, min: 1, max: 1000)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint([:workspace_id, :owner_key])
  end
end
