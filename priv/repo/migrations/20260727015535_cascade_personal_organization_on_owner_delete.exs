defmodule Hermitscale.Repo.Migrations.CascadePersonalOrganizationOnOwnerDelete do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE organizations
      DROP CONSTRAINT organizations_personal_owner_user_id_fkey,
      ADD CONSTRAINT organizations_personal_owner_user_id_fkey
        FOREIGN KEY (personal_owner_user_id)
        REFERENCES users(id)
        ON DELETE CASCADE
    """)
  end

  def down do
    execute("""
    ALTER TABLE organizations
      DROP CONSTRAINT organizations_personal_owner_user_id_fkey,
      ADD CONSTRAINT organizations_personal_owner_user_id_fkey
        FOREIGN KEY (personal_owner_user_id)
        REFERENCES users(id)
        ON DELETE NO ACTION
    """)
  end
end
