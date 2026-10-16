defmodule Hermitscale.Workspaces.Workspace do
  @moduledoc "An organization-owned Sprite."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "sprite_workspaces" do
    field :org_id, :string
    field :created_by_user_id, :string
    field :name, :string
    field :description, :string
    field :sprite_name, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def create_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :description])
    |> validate_required([:id, :org_id, :created_by_user_id, :name, :sprite_name])
    |> validate_length(:name, max: 255)
    |> unique_constraint(:sprite_name)
  end
end
