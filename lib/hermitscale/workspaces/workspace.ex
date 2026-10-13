defmodule Hermitscale.Workspaces.Workspace do
  @moduledoc "Durable organization-owned resource identity, separate from compute activity."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "workspaces" do
    field :org_id, :string
    field :created_by_user_id, :string
    field :owner_key, :string
    field :sprite_name, :string
    field :repository, :string
    field :base_sha, :string

    field :resource_state, Ecto.Enum,
      values: [:provision_pending, :retained, :deleting, :deleted],
      default: :provision_pending

    field :compute_state, Ecto.Enum, values: [:unknown, :sleeping, :running], default: :unknown
    field :generation, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def creation_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:repository, :base_sha])
    |> validate_required([:id, :org_id, :created_by_user_id, :owner_key, :sprite_name])
    |> validate_length(:owner_key, min: 1, max: 255)
    |> validate_length(:repository, max: 2048)
    |> validate_format(:base_sha, ~r/\A[0-9a-f]{40,64}\z/)
    |> unique_constraint([:org_id, :owner_key])
    |> unique_constraint(:sprite_name)
  end

  def state_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:resource_state, :compute_state, :generation])
    |> validate_required([:resource_state, :compute_state, :generation])
    |> validate_number(:generation, greater_than_or_equal_to: 0)
    |> check_constraint(:resource_state, name: :workspaces_resource_state_check)
    |> check_constraint(:compute_state, name: :workspaces_compute_state_check)
    |> check_constraint(:generation, name: :workspaces_generation_check)
  end
end
