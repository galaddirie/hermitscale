defmodule Hermitscale.Accounts.OrganizationMembership do
  @moduledoc """
  Links a user to an organization. `role` carries no behavior yet beyond
  "owner" — it exists so invites/roles can land without a migration.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "organization_memberships" do
    field :role, Ecto.Enum, values: [:owner, :admin, :member], default: :owner

    belongs_to :organization, Hermitscale.Accounts.Organization,
      foreign_key: :org_id,
      type: :string

    belongs_to :user, Hermitscale.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:org_id, :user_id, :role])
    |> validate_required([:org_id, :user_id, :role])
    |> unique_constraint([:org_id, :user_id])
  end
end
