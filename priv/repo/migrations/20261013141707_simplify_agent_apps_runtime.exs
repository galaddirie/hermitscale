defmodule Hermitscale.Repo.Migrations.SimplifyAgentAppsRuntime do
  use Ecto.Migration

  def up do
    alter table(:apps) do
      add :session_id, references(:agent_sessions, type: :uuid, with: [org_id: :org_id])
      add :start_command, :text
      add :port, :integer, null: false, default: 8080
      add :native_url, :text
      add :source_commit, :string
      add :service_status, :string, null: false, default: "stopped"
      add :public, :boolean, null: false, default: false
    end

    create index(:apps, [:session_id])
    create constraint(:apps, :apps_port_check, check: "port BETWEEN 1 AND 65535")
    flush()

    execute("""
    UPDATE apps a SET session_id = (
      SELECT s.id FROM app_build_sessions b JOIN agent_sessions s ON s.id = b.session_id
      WHERE b.app_id = a.id AND b.org_id = a.org_id AND s.org_id = a.org_id
        AND s.initiator_user_id = a.created_by_user_id
      ORDER BY b.inserted_at DESC LIMIT 1)
    """)

    alter table(:apps), do: remove(:recipe)

    alter table(:agent_sessions) do
      remove :recipe
      remove :app_id
    end

    alter table(:workspaces), do: remove(:recipe)
    alter table(:agent_events), do: modify(:turn_id, :uuid, null: true)

    drop constraint(:agent_turns, :agent_turns_budget_check)
    alter table(:agent_turns), do: remove(:budget_cents)

    create constraint(:agent_turns, :agent_turns_timeout_check,
             check: "timeout_seconds BETWEEN 30 AND 3600"
           )

    execute("DELETE FROM execution_capabilities WHERE kind <> 'product'")
    drop constraint(:execution_capabilities, :execution_capabilities_budget)

    alter table(:execution_capabilities) do
      remove :operation_id
      remove :connection
      remove :models
      remove :remaining_cost_micros
      remove :initial_cost_micros
    end

    create constraint(:execution_capabilities, :execution_capabilities_calls_check,
             check: "remaining_calls >= 0"
           )

    execute("""
    UPDATE execution_capabilities SET revoked_at = NOW()
    WHERE revoked_at IS NULL AND actions && ARRAY['deployments.request','deployments.inspect']::varchar[]
    """)

    execute("""
    UPDATE workflow_runs r SET status = 'cancelled', completed_at = NOW(),
      owner = NULL, lease_expires_at = NULL, updated_at = NOW(),
      error = '{"reason":"runtime_simplified"}'::jsonb
    WHERE r.status IN ('created','running') AND EXISTS (
      SELECT 1 FROM jsonb_array_elements(COALESCE(r.definition->'nodes','[]'::jsonb)) n
      WHERE n->>'type' IN ('agents.codex.run','agents.publish_branch','apps.preview.create',
                          'apps.deploy','apps.logs.read'))
    """)

    execute("""
    UPDATE workflow_external_operations o SET status = 'consumed', result = NULL,
      error = '{"reason":"runtime_simplified"}'::jsonb,
      outcome_digest = '#{:crypto.hash(:sha256, Jason.encode!([nil, %{"reason" => "runtime_simplified"}])) |> Base.encode16(case: :lower)}', completed_at = COALESCE(o.completed_at,NOW()),
      consumed_at = NOW(), updated_at = NOW()
    FROM workflow_runs r WHERE r.id = o.run_id AND o.status <> 'consumed'
      AND r.status = 'cancelled' AND r.error->>'reason' = 'runtime_simplified'
    """)

    execute("""
    UPDATE workflow_graphs g SET status = 'draft', validated_at = NULL, updated_at = NOW()
    WHERE g.status = 'active' AND EXISTS (
      SELECT 1 FROM jsonb_array_elements(COALESCE(g.definition->'nodes','[]'::jsonb)) n
      WHERE n->>'type' IN ('apps.deploy','apps.preview.create','apps.logs.read')
        OR (n->>'type' IN ('agents.codex.run','agents.publish_branch')
          AND COALESCE(n->'params','{}'::jsonb) ?|
            ARRAY['budget_cents','recipe','manifest','candidate_digest','patch_snapshot_artifact_id']))
    """)

    execute("""
    UPDATE workflow_triggers t SET status = 'disabled', updated_at = NOW()
    FROM workflow_graphs g WHERE g.id = t.workflow_graph_id AND g.status = 'draft'
      AND t.status = 'enabled' AND EXISTS (
        SELECT 1 FROM jsonb_array_elements(COALESCE(g.definition->'nodes','[]'::jsonb)) n
        WHERE n->>'type' IN ('apps.deploy','apps.preview.create','apps.logs.read')
          OR (n->>'type' IN ('agents.codex.run','agents.publish_branch')
            AND COALESCE(n->'params','{}'::jsonb) ?|
              ARRAY['budget_cents','recipe','manifest','candidate_digest','patch_snapshot_artifact_id']))
    """)

    drop table(:app_data_recoveries)
    drop table(:app_access_grants)
    drop table(:app_logs)
    drop table(:app_previews)
    drop table(:app_backups)
    drop table(:app_deployments)
    drop table(:app_build_sessions)
    drop table(:app_environments)
    drop table(:agent_publications)
    drop table(:artifacts)
    drop table(:usage_entries)
    drop table(:workspace_protections)
  end

  def down do
    raise Ecto.MigrationError,
          "Removed billing and hosting records cannot be recovered by rollback; restore a database backup before running the old application."
  end
end
