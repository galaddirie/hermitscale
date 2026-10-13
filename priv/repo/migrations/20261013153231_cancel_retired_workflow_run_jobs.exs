defmodule Hermitscale.Repo.Migrations.CancelRetiredWorkflowRunJobs do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE oban_jobs SET state = 'cancelled', cancelled_at = NOW()
    WHERE worker = 'Hermitscale.Workflows.RunWorker'
      AND state IN ('available','scheduled','retryable','executing')
    """)
  end

  def down, do: :ok
end
