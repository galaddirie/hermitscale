defmodule Hermitscale.Repo.Migrations.AddWorkosAuthenticationAndConnectedAccounts do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :workos_user_id, :string
      add :email_verified, :boolean, null: false, default: false
      add :first_name, :string
      add :last_name, :string
      add :profile_picture_url, :string
      add :workos_updated_at, :utc_datetime_usec
      add :deletion_pending_at, :utc_datetime
      add :deleted_at, :utc_datetime
    end

    create unique_index(:users, [:workos_user_id], where: "workos_user_id IS NOT NULL")
    create index(:users, [:deletion_pending_at], where: "deletion_pending_at IS NOT NULL")

    alter table(:organizations) do
      add :personal_owner_user_id, references(:users, on_delete: :nothing)
      add :workos_organization_id, :string
      add :provisioning_state, :string, null: false, default: "ready"
      add :workos_updated_at, :utc_datetime_usec
    end

    execute("""
    UPDATE organizations
    SET workos_organization_id = external_ref
    WHERE external_ref IS NOT NULL
    """)

    execute("""
    UPDATE organizations AS organizations
    SET personal_owner_user_id = owners.user_id
    FROM (
      SELECT DISTINCT ON (org_id) org_id, user_id
      FROM organization_memberships
      WHERE role = 'owner'
      ORDER BY org_id, inserted_at, id
    ) AS owners
    WHERE organizations.id = owners.org_id
      AND organizations.personal = TRUE
    """)

    create unique_index(:organizations, [:personal_owner_user_id],
             where: "personal_owner_user_id IS NOT NULL"
           )

    create unique_index(:organizations, [:workos_organization_id],
             where: "workos_organization_id IS NOT NULL"
           )

    create constraint(:organizations, :organizations_personal_mapping_check,
             check:
               "(personal = TRUE AND personal_owner_user_id IS NOT NULL AND workos_organization_id IS NULL) OR " <>
                 "(personal = FALSE AND personal_owner_user_id IS NULL)"
           )

    alter table(:organization_memberships) do
      add :workos_membership_id, :string
      add :source, :string, null: false, default: "local"
      add :status, :string, null: false, default: "active"
      add :workos_role_slug, :string
      add :workos_updated_at, :utc_datetime_usec
    end

    create unique_index(:organization_memberships, [:workos_membership_id],
             where: "workos_membership_id IS NOT NULL"
           )

    create index(:organization_memberships, [:org_id, :status])
    create index(:organization_memberships, [:user_id, :status])

    create constraint(:organization_memberships, :organization_memberships_source_check,
             check: "source IN ('local', 'workos')"
           )

    create constraint(:organization_memberships, :organization_memberships_status_check,
             check: "status IN ('active', 'inactive', 'deleted')"
           )

    create table(:auth_sessions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :token_hash, :binary, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :org_id, references(:organizations, type: :string, on_delete: :nothing)
      add :workos_session_id, :string, null: false
      add :encryption_key_id, :string, null: false
      add :access_token_ciphertext, :binary, null: false
      add :refresh_token_ciphertext, :binary, null: false
      add :access_expires_at, :utc_datetime, null: false
      add :authenticated_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:auth_sessions, [:token_hash])
    create unique_index(:auth_sessions, [:workos_session_id])
    create index(:auth_sessions, [:user_id])
    create index(:auth_sessions, [:org_id])
    create index(:auth_sessions, [:access_expires_at])
    create index(:auth_sessions, [:revoked_at], where: "revoked_at IS NULL")

    create table(:workos_authorization_states) do
      add :token_hash, :binary, null: false
      add :return_to, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workos_authorization_states, [:token_hash])
    create index(:workos_authorization_states, [:expires_at])

    create table(:connected_account_intents) do
      add :token_hash, :binary, null: false
      add :owner_user_id, references(:users, on_delete: :delete_all), null: false
      add :org_id, references(:organizations, type: :string, on_delete: :delete_all), null: false
      add :provider_id, :string, null: false
      add :provider_slug, :string, null: false
      add :sharing_mode, :string, null: false, default: "private"
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:connected_account_intents, [:token_hash])
    create index(:connected_account_intents, [:owner_user_id])
    create index(:connected_account_intents, [:org_id])
    create index(:connected_account_intents, [:owner_user_id, :org_id, :provider_slug])

    create constraint(:connected_account_intents, :connected_account_intents_sharing_mode_check,
             check: "sharing_mode IN ('private', 'organization')"
           )

    create table(:connected_accounts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :owner_user_id, references(:users, on_delete: :nothing), null: false
      add :org_id, references(:organizations, type: :string, on_delete: :nothing), null: false
      add :provider_id, :string, null: false
      add :provider_slug, :string, null: false
      add :backend, :string, null: false, default: "workos_pipes"
      add :workos_connected_account_id, :string
      add :workos_organization_id, :string
      add :state, :string, null: false, default: "pending"
      add :sharing_mode, :string, null: false, default: "private"
      add :granted_scopes, {:array, :string}, null: false, default: []
      add :workos_updated_at, :utc_datetime_usec
      add :disconnected_at, :utc_datetime
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:connected_accounts, [:owner_user_id])
    create index(:connected_accounts, [:org_id])
    create index(:connected_accounts, [:org_id, :state])
    create index(:connected_accounts, [:provider_id])

    create unique_index(:connected_accounts, [:workos_connected_account_id],
             where: "workos_connected_account_id IS NOT NULL"
           )

    create unique_index(
             :connected_accounts,
             [:owner_user_id, :provider_slug, :workos_organization_id],
             where: "workos_organization_id IS NOT NULL",
             name: :connected_accounts_workos_tuple_with_org_index
           )

    create unique_index(:connected_accounts, [:owner_user_id, :provider_slug],
             where: "workos_organization_id IS NULL",
             name: :connected_accounts_workos_tuple_without_org_index
           )

    create constraint(:connected_accounts, :connected_accounts_backend_check,
             check: "backend IN ('legacy_google', 'workos_pipes')"
           )

    create constraint(:connected_accounts, :connected_accounts_state_check,
             check:
               "state IN ('pending', 'connected', 'needs_reauthorization', 'disconnecting', 'disconnected')"
           )

    create constraint(:connected_accounts, :connected_accounts_sharing_mode_check,
             check: "sharing_mode IN ('private', 'organization')"
           )

    create table(:workos_events, primary_key: false) do
      add :event_id, :string, primary_key: true
      add :event_type, :string, null: false
      add :payload, :map, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :status, :string, null: false, default: "pending"
      add :processed_at, :utc_datetime
      add :processing_error, :text

      timestamps(type: :utc_datetime)
    end

    create index(:workos_events, [:status, :occurred_at])
    create index(:workos_events, [:event_type])

    create constraint(:workos_events, :workos_events_status_check,
             check: "status IN ('pending', 'processed', 'ignored', 'failed')"
           )

    create table(:workos_event_cursors, primary_key: false) do
      add :stream, :string, primary_key: true
      add :after_cursor, :string

      timestamps(type: :utc_datetime)
    end
  end

  def down do
    drop table(:workos_event_cursors)
    drop table(:workos_events)
    drop table(:connected_accounts)
    drop table(:connected_account_intents)
    drop table(:workos_authorization_states)
    drop table(:auth_sessions)

    drop constraint(:organization_memberships, :organization_memberships_source_check)
    drop constraint(:organization_memberships, :organization_memberships_status_check)
    drop_if_exists index(:organization_memberships, [:org_id, :status])
    drop_if_exists index(:organization_memberships, [:user_id, :status])
    drop_if_exists index(:organization_memberships, [:workos_membership_id])

    alter table(:organization_memberships) do
      remove :workos_membership_id
      remove :source
      remove :status
      remove :workos_role_slug
      remove :workos_updated_at
    end

    drop constraint(:organizations, :organizations_personal_mapping_check)
    drop_if_exists index(:organizations, [:personal_owner_user_id])
    drop_if_exists index(:organizations, [:workos_organization_id])

    alter table(:organizations) do
      remove :personal_owner_user_id
      remove :workos_organization_id
      remove :provisioning_state
      remove :workos_updated_at
    end

    drop_if_exists index(:users, [:deletion_pending_at])
    drop_if_exists index(:users, [:workos_user_id])

    alter table(:users) do
      remove :workos_user_id
      remove :email_verified
      remove :first_name
      remove :last_name
      remove :profile_picture_url
      remove :workos_updated_at
      remove :deletion_pending_at
      remove :deleted_at
    end
  end
end
