defmodule Hermitscale.Repo.Migrations.RemoveWorkflowExternalOperations do
  use Ecto.Migration

  def up do
    # Old callbacks have different component identities. Keep their history,
    # but do not repeat unfinished effects through the native runner.
    execute("""
    UPDATE workflow_runs r SET status = 'cancelled', completed_at = NOW(), updated_at = NOW(),
      error = '{"reason":"external_operations_removed"}'::jsonb
    WHERE r.status IN ('created','running') AND (
      EXISTS (SELECT 1 FROM workflow_external_operations o WHERE o.run_id = r.id)
      OR EXISTS (
        SELECT 1 FROM jsonb_array_elements(COALESCE(r.definition->'nodes','[]'::jsonb)) n
        WHERE n->>'type' IN ('agents.codex.run','agents.publish_branch','apps.preview.create',
                            'apps.publish','apps.logs.read')))
    """)

    # Ordinary keyed runs already have native planned events and can resume
    # through the durable run job. The removed operation jobs cannot.
    execute("""
    UPDATE oban_jobs j SET worker = 'Hermitscale.Workflows.RunWorker', queue = 'workflows'
    WHERE j.worker = 'Hermitscale.Workflows.ExternalOperationWorker'
      AND j.state IN ('available','scheduled','retryable') AND j.args ? 'run_id'
      AND EXISTS (SELECT 1 FROM workflow_runs r WHERE r.id = j.args->>'run_id'
                  AND r.status IN ('created','running'))
    """)

    execute("""
    UPDATE oban_jobs SET state = 'cancelled', cancelled_at = NOW()
    WHERE worker = 'Hermitscale.Workflows.ExternalOperationWorker'
      AND state IN ('available','scheduled','retryable','executing')
    """)

    drop table(:workflow_external_operations)

    alter table(:workflow_runs) do
      remove :owner
      remove :lease_expires_at
    end
  end

  def down do
    raise Ecto.MigrationError,
          "Removed workflow operation records cannot be recovered by rollback; restore a database backup before running the old application."
  end
end
