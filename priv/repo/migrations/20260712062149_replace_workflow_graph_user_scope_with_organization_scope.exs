defmodule Hermitscale.Repo.Migrations.ReplaceWorkflowGraphUserScopeWithOrganizationScope do
  use Ecto.Migration

  def up do
    alter table(:workflow_graphs) do
      add :org_id, references(:organizations, type: :string, on_delete: :delete_all)
    end

    flush()

    # Users created before organizations were introduced need a personal
    # organization before existing workflow ownership can be migrated.
    execute("""
    INSERT INTO organizations (id, name, personal, inserted_at, updated_at)
    SELECT
      'legacy-user-' || users.id::text,
      COALESCE(NULLIF(split_part(users.email::text, '@', 1), ''), 'Personal'),
      TRUE,
      NOW(),
      NOW()
    FROM users
    WHERE NOT EXISTS (
      SELECT 1
      FROM organization_memberships AS memberships
      INNER JOIN organizations
        ON organizations.id = memberships.org_id
      WHERE memberships.user_id = users.id
        AND organizations.personal = TRUE
    )
    ON CONFLICT (id) DO NOTHING
    """)

    execute("""
    INSERT INTO organization_memberships
      (org_id, user_id, role, inserted_at, updated_at)
    SELECT
      organizations.id,
      users.id,
      'owner',
      NOW(),
      NOW()
    FROM users
    INNER JOIN organizations
      ON organizations.id = 'legacy-user-' || users.id::text
      AND organizations.personal = TRUE
    LEFT JOIN organization_memberships AS memberships
      ON memberships.org_id = organizations.id
      AND memberships.user_id = users.id
    WHERE memberships.id IS NULL
    ON CONFLICT (org_id, user_id) DO NOTHING
    """)

    execute("""
    UPDATE workflow_graphs AS graphs
    SET org_id = (
      SELECT memberships.org_id
      FROM organization_memberships AS memberships
      INNER JOIN organizations
        ON organizations.id = memberships.org_id
      WHERE memberships.user_id = graphs.user_id
      ORDER BY
        organizations.personal DESC,
        memberships.inserted_at ASC,
        memberships.id ASC
      LIMIT 1
    )
    WHERE graphs.user_id IS NOT NULL
      AND graphs.org_id IS NULL
    """)

    rename table(:workflow_graphs), :user_id, to: :created_by_user_id
    flush()

    # Creator identity is audit metadata. Removing a user must not delete an
    # organization's shared workflow.
    execute("""
    ALTER TABLE workflow_graphs
      DROP CONSTRAINT workflow_graphs_user_id_fkey,
      ADD CONSTRAINT workflow_graphs_created_by_user_id_fkey
        FOREIGN KEY (created_by_user_id)
        REFERENCES users(id)
        ON DELETE SET NULL
    """)

    execute("""
    ALTER INDEX workflow_graphs_user_id_index
      RENAME TO workflow_graphs_created_by_user_id_index
    """)

    create index(:workflow_graphs, [:org_id])
  end

  def down do
    drop index(:workflow_graphs, [:org_id])

    execute("""
    ALTER TABLE workflow_graphs
      DROP CONSTRAINT workflow_graphs_created_by_user_id_fkey
    """)

    execute("""
    ALTER INDEX workflow_graphs_created_by_user_id_index
      RENAME TO workflow_graphs_user_id_index
    """)

    rename table(:workflow_graphs), :created_by_user_id, to: :user_id
    flush()

    execute("""
    ALTER TABLE workflow_graphs
      ADD CONSTRAINT workflow_graphs_user_id_fkey
        FOREIGN KEY (user_id)
        REFERENCES users(id)
        ON DELETE CASCADE
    """)

    alter table(:workflow_graphs) do
      remove :org_id
    end
  end
end
