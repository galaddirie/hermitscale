defmodule Hermitscale.Repo.Migrations.CompleteAgentsProductRuntime do
  use Ecto.Migration

  def change do
    create table(:reviews, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false
      add :requested_by_user_id, :string, null: false
      add :operation_key, :string, null: false
      add :action, :string, null: false
      add :target_digest, :string, null: false
      add :policy_revision, :integer, null: false, default: 1
      add :eligible_approver_ids, {:array, :string}, null: false
      add :expires_at, :utc_datetime, null: false
      add :status, :string, null: false, default: "requested"
      add :decided_by_user_id, :string
      add :decided_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:reviews, [:org_id, :operation_key])
    create unique_index(:reviews, [:id, :org_id])

    create constraint(:reviews, :reviews_status,
             check: "status IN ('requested','approved','rejected')"
           )

    create table(:artifacts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false
      add :created_by_user_id, :string, null: false
      add :owner_type, :string, null: false
      add :owner_id, :string, null: false
      add :kind, :string, null: false
      add :digest, :string, null: false
      add :content_type, :string, null: false
      add :size_bytes, :bigint, null: false
      add :content, :binary, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:artifacts, [:org_id, :owner_type, :owner_id, :kind, :digest])
    create unique_index(:artifacts, [:id, :org_id])

    create constraint(:artifacts, :artifacts_size,
             check: "size_bytes >= 0 AND size_bytes <= 8388608"
           )

    create table(:usage_entries, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false
      add :operation_id, :string, null: false
      add :category, :string, null: false
      add :deduplication_key, :string, null: false
      add :quantity, :bigint, null: false
      add :cost_micros, :bigint, null: false
      add :rate_version, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:usage_entries, [:org_id, :deduplication_key])
    create index(:usage_entries, [:org_id, :operation_id])

    create constraint(:usage_entries, :usage_nonnegative,
             check:
               "quantity >= 0 AND cost_micros >= 0 AND category IN ('compute','storage','model')"
           )

    create table(:execution_capabilities, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false
      add :actor_user_id, :string, null: false
      add :token_digest, :string, null: false
      add :kind, :string, null: false
      add :resource_ids, {:array, :string}, null: false
      add :actions, {:array, :string}, null: false
      add :operation_id, :string
      add :connection, :map, null: false, default: %{}
      add :models, {:array, :string}, null: false, default: []
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime
      add :remaining_calls, :integer, null: false
      add :remaining_cost_micros, :bigint, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:execution_capabilities, [:token_digest])
    create index(:execution_capabilities, [:org_id, :operation_id])

    alter table(:agent_sessions) do
      add :operation_key, :string
      add :app_id, :uuid
      add :connection_set, :map, null: false, default: %{}
      add :provider_conversation_id, :string
    end

    create unique_index(:agent_sessions, [:org_id, :initiator_user_id, :operation_key],
             where: "operation_key IS NOT NULL"
           )

    alter table(:agent_turns) do
      add :lease_id, references(:workspace_leases, type: :uuid, on_delete: :restrict)
      add :worker_command_id, :uuid
      add :cancel_command_id, :uuid
      add :worker_epoch, :string
      add :worker_cursor, :bigint, null: false, default: 0
      add :provider_conversation_id, :string
      add :review_id, references(:reviews, type: :uuid, on_delete: :restrict)
      add :result_schema, :map, null: false, default: %{}
      add :runtime_state, :map, null: false, default: %{}
    end

    create table(:agent_publications, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false

      add :session_id,
          references(:agent_sessions, type: :uuid, with: [org_id: :org_id], on_delete: :restrict),
          null: false

      add :execution_actor_user_id, :string, null: false
      add :operation_key, :string, null: false
      add :payload_digest, :string, null: false
      add :specification, :map, null: false
      add :status, :string, null: false, default: "queued"
      add :result, :map
      add :error, :map
      add :lease_id, references(:workspace_leases, type: :uuid)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_publications, [:org_id, :operation_key])
    create index(:agent_publications, [:session_id])

    create table(:integration_deliveries, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false
      add :actor_user_id, :string, null: false
      add :effect_key, :string, null: false
      add :provider, :string, null: false
      add :payload_digest, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :result, :map
      timestamps(type: :utc_datetime)
    end

    create unique_index(:integration_deliveries, [:org_id, :effect_key])
    create index(:integration_deliveries, [:org_id, :actor_user_id])

    create constraint(:integration_deliveries, :integration_deliveries_status,
             check: "status IN ('pending','uncertain','succeeded')"
           )
  end
end
