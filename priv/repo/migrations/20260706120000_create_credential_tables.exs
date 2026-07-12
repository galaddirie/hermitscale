defmodule Hermitscale.Repo.Migrations.CreateCredentialTables do
  use Ecto.Migration

  def change do
    create table(:credentials, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, :string, null: false
      add :user_id, :string
      add :provider, :string, null: false
      add :kind, :string, null: false
      add :method, :string, null: false
      add :name, :string, null: false
      add :status, :string, null: false, default: "pending_connect"
      add :backend, :string, null: false
      add :external_ref, :string
      add :provider_metadata, :map, null: false, default: %{}
      add :scopes, {:array, :string}, null: false, default: []
      add :expires_at, :utc_datetime
      add :last_used_at, :utc_datetime
      add :rotated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:credentials, [:org_id, :provider])
    create index(:credentials, [:org_id, :status])

    create table(:credential_events) do
      add :credential_id,
          references(:credentials, type: :string, on_delete: :delete_all),
          null: false

      add :action, :string, null: false
      add :actor, :string, null: false
      add :context, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:credential_events, [:credential_id])

    create table(:credential_secrets) do
      add :credential_id,
          references(:credentials, type: :string, on_delete: :delete_all),
          null: false

      add :payload, :binary, null: false
      add :version, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:credential_secrets, [:credential_id, :version])
  end
end
