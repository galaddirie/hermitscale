defmodule Hermitscale.Repo.RemoveIdentityProjectionsTest do
  use ExUnit.Case, async: false

  alias Hermitscale.Repo
  alias Hermitscale.Repo.Migrations.RemoveLocalWorkosIdentityProjections

  test "preserves mapped and unmapped workflows while removing identity projections" do
    # A disposable schema isolates the old table shape from the test database's
    # current schema. Its identifiers are generated here, never from user input.
    schema = "identity_migration_#{System.unique_integer([:positive])}"
    config = Repo.config() |> Keyword.take([:username, :password, :hostname, :port, :database])
    connection = start_supervised!({Postgrex, config})
    Postgrex.query!(connection, "CREATE SCHEMA \"#{schema}\"", [])

    try do
      start_supervised!(
        {Repo,
         Keyword.merge(config,
           name: Hermitscale.IdentityMigrationRepo,
           pool: DBConnection.ConnectionPool,
           pool_size: 2,
           parameters: [search_path: schema]
         )},
        id: Hermitscale.IdentityMigrationRepo
      )

      previous = Repo.put_dynamic_repo(Hermitscale.IdentityMigrationRepo)

      try do
        seed_old_tables()

        migration_path =
          Path.expand(
            "../../../priv/repo/migrations/20261012015826_remove_local_workos_identity_projections.exs",
            __DIR__
          )

        Code.require_file(migration_path)

        assert :ok =
                 Ecto.Migrator.up(Repo, 20_261_012_015_826, RemoveLocalWorkosIdentityProjections,
                   prefix: schema,
                   log: false
                 )

        assert query("SELECT id, org_id, created_by_user_id FROM workflow_graphs ORDER BY id").rows ==
                 [
                   ["mapped", "org_workos", "user_workos"],
                   ["unmapped", "legacy-org", "legacy-user-2"]
                 ]

        assert query("SELECT workflow_graph_id FROM triggers").rows == [["mapped"]]
        assert query("SELECT workflow_graph_id FROM workflow_runs").rows == [["mapped"]]
        assert query("SELECT run_id FROM workflow_run_events").rows == [["run"]]

        assert query("SELECT worker, state FROM oban_jobs ORDER BY worker").rows == [
                 ["Hermitscale.Triggers.FireWorker", "available"],
                 ["Hermitscale.WorkOS.EventsConsumer", "cancelled"]
               ]

        assert query(
                 "SELECT to_regclass('users'), to_regclass('organizations'), to_regclass('connected_accounts')"
               ).rows == [[nil, nil, nil]]
      after
        Repo.put_dynamic_repo(previous)
      end
    after
      Postgrex.query!(connection, "DROP SCHEMA \"#{schema}\" CASCADE", [])
    end
  end

  defp seed_old_tables do
    for sql <- [
          "CREATE TABLE users (id bigint PRIMARY KEY, workos_user_id varchar)",
          "CREATE TABLE organizations (id varchar PRIMARY KEY, workos_organization_id varchar)",
          "CREATE TABLE workflow_graphs (id varchar PRIMARY KEY, org_id varchar REFERENCES organizations(id) ON DELETE CASCADE, created_by_user_id bigint REFERENCES users(id) ON DELETE SET NULL)",
          "CREATE TABLE workflow_runs (id varchar PRIMARY KEY, workflow_graph_id varchar REFERENCES workflow_graphs(id))",
          "CREATE TABLE workflow_run_events (run_id varchar REFERENCES workflow_runs(id))",
          "CREATE TABLE triggers (workflow_graph_id varchar REFERENCES workflow_graphs(id))",
          "CREATE TABLE oban_jobs (worker varchar, state varchar, cancelled_at timestamp)",
          "CREATE TABLE connected_account_intents (id bigint)",
          "CREATE TABLE connected_accounts (id bigint)",
          "CREATE TABLE workos_authorization_states (id bigint)",
          "CREATE TABLE auth_sessions (id bigint)",
          "CREATE TABLE workos_state_reconciliations (id bigint)",
          "CREATE TABLE workos_event_cursors (id bigint)",
          "CREATE TABLE workos_events (id bigint)",
          "CREATE TABLE users_tokens (id bigint)",
          "CREATE TABLE organization_memberships (id bigint)",
          "INSERT INTO users VALUES (1, 'user_workos'), (2, NULL)",
          "INSERT INTO organizations VALUES ('mapped-org', 'org_workos'), ('legacy-org', NULL)",
          "INSERT INTO workflow_graphs VALUES ('mapped', 'mapped-org', 1), ('unmapped', 'legacy-org', 2)",
          "INSERT INTO workflow_runs VALUES ('run', 'mapped')",
          "INSERT INTO workflow_run_events VALUES ('run')",
          "INSERT INTO triggers VALUES ('mapped')",
          "INSERT INTO oban_jobs VALUES ('Hermitscale.WorkOS.EventsConsumer', 'available', NULL), ('Hermitscale.Triggers.FireWorker', 'available', NULL)"
        ] do
      query(sql)
    end
  end

  defp query(sql), do: Repo.query!(sql, [])
end
