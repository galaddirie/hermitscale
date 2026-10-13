defmodule Hermitscale.Workspaces.Lease do
  @moduledoc "Bounded exclusive writer admission and verified termination evidence."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "workspace_leases" do
    field :org_id, :string
    belongs_to :workspace, Hermitscale.Workspaces.Workspace
    field :execution_actor_user_id, :string
    field :operation_key, :string
    field :generation, :integer
    field :deadline, :utc_datetime_usec
    field :status, Ecto.Enum, values: [:active, :released], default: :active
    field :termination_evidence, :map, default: %{}
    field :released_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def creation_changeset(lease, attrs) do
    lease
    |> cast(attrs, [:operation_key, :deadline])
    |> validate_required([
      :workspace_id,
      :org_id,
      :execution_actor_user_id,
      :operation_key,
      :generation,
      :deadline
    ])
    |> validate_length(:operation_key, min: 1, max: 255)
    |> validate_number(:generation, greater_than: 0)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint([:workspace_id, :operation_key])
    |> unique_constraint(:workspace_id, name: :workspace_leases_one_active_writer)
    |> check_constraint(:generation, name: :workspace_leases_generation_check)
  end

  def release_changeset(lease, evidence) do
    lease
    |> change(status: :released, released_at: DateTime.utc_now(), termination_evidence: evidence)
    |> check_constraint(:status, name: :workspace_leases_status_check)
    |> check_constraint(:released_at, name: :workspace_leases_release_check)
  end
end
