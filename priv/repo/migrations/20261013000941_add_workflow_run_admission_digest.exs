defmodule Hermitscale.Repo.Migrations.AddWorkflowRunAdmissionDigest do
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      add :admission_digest, :string
    end
  end
end
