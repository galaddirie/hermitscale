defmodule Hermitscale.Repo.Migrations.CreateAgentConversations do
  use Ecto.Migration

  def change do
    create table(:agent_sessions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false
      add :initiator_user_id, :string, null: false

      add :workspace_id,
          references(:workspaces, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
          null: false

      add :title, :string, null: false
      add :repository, :string
      add :base_sha, :string
      add :recipe, :string, null: false
      add :status, :string, null: false, default: "open"
      add :last_event_sequence, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_sessions, [:workspace_id])
    create unique_index(:agent_sessions, [:id, :org_id])
    create index(:agent_sessions, [:org_id, :initiator_user_id, :updated_at])

    create constraint(:agent_sessions, :agent_sessions_status_check,
             check: "status IN ('open', 'archived', 'closed')"
           )

    create constraint(:agent_sessions, :agent_sessions_sequence_check,
             check: "last_event_sequence >= 0"
           )

    create table(:agent_turns, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false

      add :session_id,
          references(:agent_sessions, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
          null: false

      add :execution_actor_user_id, :string, null: false
      add :instructions, :text, null: false
      add :operation_key, :string, null: false
      add :input_digest, :string, null: false
      add :admission_sequence, :bigint, null: false
      add :budget_cents, :integer, null: false
      add :timeout_seconds, :integer, null: false
      add :deadline, :utc_datetime, null: false
      add :status, :string, null: false, default: "queued"
      add :cancellation_requested_at, :utc_datetime
      add :dispatched_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :result, :map
      add :error, :map
      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_turns, [:session_id, :operation_key])
    create unique_index(:agent_turns, [:session_id, :admission_sequence])

    create unique_index(:agent_turns, [:session_id],
             where:
               "status IN ('provisioning', 'running', 'waiting_for_input', 'waiting_for_approval')",
             name: :agent_turns_one_active_turn
           )

    create unique_index(:agent_turns, [:id, :org_id])
    create unique_index(:agent_turns, [:id, :session_id, :org_id])
    create index(:agent_turns, [:session_id, :status])

    create constraint(:agent_turns, :agent_turns_status_check,
             check:
               "status IN ('queued', 'provisioning', 'running', 'waiting_for_input', 'waiting_for_approval', 'interrupted', 'succeeded', 'failed', 'cancelled')"
           )

    create constraint(:agent_turns, :agent_turns_budget_check,
             check:
               "budget_cents > 0 AND budget_cents <= 10000 AND timeout_seconds >= 30 AND timeout_seconds <= 3600"
           )

    create table(:agent_events, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false

      add :session_id,
          references(:agent_sessions, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
          null: false

      add :turn_id,
          references(:agent_turns,
            type: :uuid,
            with: [session_id: :session_id, org_id: :org_id],
            on_delete: :restrict
          ),
          null: false

      add :sequence, :bigint, null: false
      add :source_key, :string, null: false
      add :source_digest, :string, null: false
      add :type, :string, null: false
      add :payload, :map, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_events, [:session_id, :sequence])
    create unique_index(:agent_events, [:session_id, :source_key])
    create index(:agent_events, [:turn_id])
    create constraint(:agent_events, :agent_events_sequence_check, check: "sequence > 0")
  end
end
