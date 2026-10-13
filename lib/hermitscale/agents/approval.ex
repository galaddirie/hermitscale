defmodule Hermitscale.Agents.Approval do
  @moduledoc "A native provider permission request bound to one admitted turn."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "agent_approvals" do
    field :org_id, :string
    belongs_to :turn, Hermitscale.Agents.Turn
    field :action, :string
    field :target_digest, :string
    field :policy_revision, :integer, default: 1
    field :status, Ecto.Enum, values: [:pending, :approved, :rejected], default: :pending
    field :decided_by_user_id, :string
    field :expires_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [:action, :target_digest, :policy_revision])
    |> validate_required([:id, :org_id, :turn_id, :action, :target_digest, :expires_at])
    |> validate_inclusion(:action, ["agents.approve"])
    |> validate_format(:target_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:policy_revision, greater_than: 0)
    |> foreign_key_constraint(:turn_id)
    |> unique_constraint(:id, name: :agent_approvals_pkey)
  end
end
