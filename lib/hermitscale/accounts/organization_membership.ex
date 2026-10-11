defmodule Hermitscale.Accounts.OrganizationMembership do
  @moduledoc """
  Links a user to an organization. `role` carries no behavior yet beyond
  "owner" — it exists so invites/roles can land without a migration.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "organization_memberships" do
    field :role, Ecto.Enum, values: [:owner, :admin, :member], default: :owner
    field :source, Ecto.Enum, values: [:local, :workos], default: :local
    field :status, Ecto.Enum, values: [:active, :inactive, :deleted], default: :active
    field :workos_membership_id, :string
    field :workos_role_slug, :string
    field :workos_updated_at, :utc_datetime_usec

    belongs_to :organization, Hermitscale.Accounts.Organization,
      foreign_key: :org_id,
      type: :string

    belongs_to :user, Hermitscale.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [
      :org_id,
      :user_id,
      :role,
      :source,
      :status,
      :workos_membership_id,
      :workos_role_slug,
      :workos_updated_at
    ])
    |> validate_required([:org_id, :user_id, :role, :source, :status])
    |> unique_constraint([:org_id, :user_id])
    |> unsafe_validate_unique(:workos_membership_id, Hermitscale.Repo)
    |> unique_constraint(:workos_membership_id)
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:source, name: :organization_memberships_source_check)
    |> check_constraint(:status, name: :organization_memberships_status_check)
  end
end
