defmodule Hermitscale.Accounts.Organization do
  @moduledoc """
  A tenancy boundary. Every user gets a personal organization at
  registration; shared organizations (invites, roles) come later — the
  membership `role` column is the seam.

  Ids are string UUIDs to match the scope columns that predate this schema
  (`credentials.org_id`), so those columns can hold real org ids without a
  type migration. `external_ref` links organizations JIT-provisioned from an
  identity provider (e.g. a WorkOS organization id).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "organizations" do
    field :name, :string
    field :personal, :boolean, default: false
    field :external_ref, :string

    has_many :memberships, Hermitscale.Accounts.OrganizationMembership, foreign_key: :org_id

    timestamps(type: :utc_datetime)
  end

  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:id, :name, :personal, :external_ref])
    |> validate_required([:id, :name])
    |> validate_length(:name, max: 160)
    |> unique_constraint(:external_ref)
  end
end
