defmodule Hermitscale.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  def change do
    create table(:organizations, primary_key: false) do
      # String UUID to match the credentials.org_id column convention, so
      # existing scope columns can reference real orgs without a type change.
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :personal, :boolean, null: false, default: false
      # Identity-provider reference (e.g. WorkOS organization id) for
      # JIT-provisioned organizations.
      add :external_ref, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organizations, [:external_ref], where: "external_ref IS NOT NULL")

    create table(:organization_memberships) do
      add :org_id, references(:organizations, type: :string, on_delete: :delete_all), null: false

      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "owner"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organization_memberships, [:org_id, :user_id])
    create index(:organization_memberships, [:user_id])
  end
end
