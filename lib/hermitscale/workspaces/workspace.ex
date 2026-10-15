defmodule Hermitscale.Workspaces.Workspace do
  @moduledoc "An organization-owned Sprite and its retained provisioning/deletion intent."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "sprite_workspaces" do
    field :org_id, :string
    field :created_by_user_id, :string
    field :name, :string
    field :description, :string
    field :sprite_name, :string

    field :status, Ecto.Enum,
      values: [:provisioning, :ready, :failed, :deleting],
      default: :provisioning

    field :sprite_data, :map, default: %{}
    field :last_error, :map
    field :lock_version, :integer, default: 1

    timestamps(type: :utc_datetime)
  end

  @doc false
  def create_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :description])
    |> validate_required([:id, :org_id, :created_by_user_id, :name, :sprite_name, :status])
    |> validate_length(:name, max: 255)
    |> unique_constraint(:sprite_name)
  end

  @doc false
  def lifecycle_changeset(workspace, attrs) do
    workspace
    |> change(attrs)
    |> validate_required([:status, :sprite_data])
    |> optimistic_lock(:lock_version)
  end
end
