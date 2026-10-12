defmodule Hermitscale.Repo.Migrations.RemoveLocalWorkosIdentityProjections do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE workflow_graphs DROP CONSTRAINT workflow_graphs_org_id_fkey")

    execute("""
    ALTER TABLE workflow_graphs
      DROP CONSTRAINT workflow_graphs_created_by_user_id_fkey,
      ALTER COLUMN created_by_user_id TYPE varchar(255)
        USING CASE WHEN created_by_user_id IS NULL THEN NULL
          ELSE 'legacy-user-' || created_by_user_id::text END
    """)

    # Retain application data and translate identities before removing projections.
    # Unmapped legacy identities remain orphaned; they cannot vend WorkOS tokens.
    execute("""
    UPDATE workflow_graphs AS graphs
    SET org_id = organizations.workos_organization_id
    FROM organizations
    WHERE graphs.org_id = organizations.id
      AND organizations.workos_organization_id IS NOT NULL
    """)

    execute("""
    UPDATE workflow_graphs AS graphs
    SET created_by_user_id = users.workos_user_id
    FROM users
    WHERE graphs.created_by_user_id = 'legacy-user-' || users.id::text
      AND users.workos_user_id IS NOT NULL
    """)

    drop_if_exists table(:connected_account_intents)
    drop_if_exists table(:connected_accounts)
    drop_if_exists table(:workos_authorization_states)
    drop_if_exists table(:auth_sessions)
    drop_if_exists table(:workos_state_reconciliations)
    drop_if_exists table(:workos_event_cursors)
    drop_if_exists table(:workos_events)
    drop_if_exists table(:users_tokens)
    drop_if_exists table(:organization_memberships)
    drop_if_exists table(:organizations)
    drop_if_exists table(:users)

    # Pending identity synchronization/deletion jobs refer to removed projections.
    execute("""
    UPDATE oban_jobs
    SET state = 'cancelled', cancelled_at = NOW()
    WHERE worker IN (
      'Hermitscale.Accounts.OrganizationProvisioningWorker',
      'Hermitscale.Accounts.AccountDeletionWorker',
      'Hermitscale.WorkOS.EventProcessor',
      'Hermitscale.WorkOS.EventsConsumer',
      'Hermitscale.WorkOS.EventRetentionWorker',
      'Hermitscale.WorkOS.StateReconciler'
    ) AND state IN ('available', 'scheduled', 'retryable')
    """)
  end

  def down do
    raise Ecto.MigrationError,
          "WorkOS identity projections were removed; restore a database backup to roll back"
  end
end
