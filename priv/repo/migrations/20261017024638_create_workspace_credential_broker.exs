defmodule Hermitscale.Repo.Migrations.CreateWorkspaceCredentialBroker do
  use Ecto.Migration

  def change do
    create table(:workspace_credential_grants, primary_key: false) do
      add :id, :string, primary_key: true

      add :workspace_id, references(:sprite_workspaces, type: :string, on_delete: :delete_all),
        null: false

      add :org_id, :string, null: false
      add :provider, :string, null: false
      add :account_id, :string, null: false
      add :rules, {:array, :string}, null: false
      add :created_by_user_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_credential_grants, [:workspace_id, :provider])
    create index(:workspace_credential_grants, [:org_id])

    create table(:workspace_broker_tokens, primary_key: false) do
      add :id, :string, primary_key: true

      add :workspace_id, references(:sprite_workspaces, type: :string, on_delete: :delete_all),
        null: false

      add :org_id, :string, null: false
      add :actor_user_id, :string, null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_broker_tokens, [:token_hash])
    create index(:workspace_broker_tokens, [:workspace_id])
  end
end
