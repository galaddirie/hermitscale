defmodule Hermitscale.Accounts.Organization do
  @moduledoc """
  A tenancy boundary. Every user gets a personal organization at
  registration; shared organizations (invites, roles) come later — the
  membership `role` column is the seam.

  Ids are string UUIDs so scope columns in other contexts can store org ids
  as plain strings. WorkOS organization ids are mappings only and never
  replace the local tenancy key.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "organizations" do
    field :name, :string
    field :personal, :boolean, default: false
    field :external_ref, :string
    field :workos_organization_id, :string

    field :provisioning_state, Ecto.Enum,
      values: [:provisioning, :ready, :unavailable],
      default: :ready

    field :workos_updated_at, :utc_datetime_usec

    has_many :memberships, Hermitscale.Accounts.OrganizationMembership, foreign_key: :org_id

    belongs_to :personal_owner, Hermitscale.Accounts.User, foreign_key: :personal_owner_user_id

    timestamps(type: :utc_datetime)
  end

  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [
      :id,
      :name,
      :personal,
      :external_ref,
      :personal_owner_user_id,
      :workos_organization_id,
      :provisioning_state,
      :workos_updated_at
    ])
    |> validate_required([:id, :name])
    |> validate_length(:name, max: 160)
    |> unique_constraint(:external_ref)
    |> unsafe_validate_unique(:personal_owner_user_id, Hermitscale.Repo)
    |> unique_constraint(:personal_owner_user_id)
    |> unsafe_validate_unique(:workos_organization_id, Hermitscale.Repo)
    |> unique_constraint(:workos_organization_id)
    |> foreign_key_constraint(:personal_owner_user_id)
    |> check_constraint(:personal,
      name: :organizations_personal_mapping_check,
      message: "has an invalid owner or WorkOS mapping"
    )
  end
end
