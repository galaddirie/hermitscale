defmodule Hermitscale.Repo.Migrations.RemoveExampleWorkflowDomains do
  use Ecto.Migration

  def up do
    create table(:agent_approvals, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false
      add :turn_id, references(:agent_turns, type: :uuid, with: [org_id: :org_id]), null: false
      add :action, :string, null: false
      add :target_digest, :string, null: false
      add :policy_revision, :integer, null: false, default: 1
      add :status, :string, null: false, default: "pending"
      add :decided_by_user_id, :string
      add :expires_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_approvals, [:id, :org_id])
    create index(:agent_approvals, [:turn_id])

    create constraint(:agent_approvals, :agent_approvals_status,
             check: "status IN ('pending','approved','rejected')"
           )

    alter table(:agent_turns) do
      add :approval_id, references(:agent_approvals, type: :uuid, with: [org_id: :org_id])
      add :verification_commands, {:array, :string}, null: false, default: []
    end

    flush()

    execute("""
    INSERT INTO agent_approvals
      (id, org_id, turn_id, action, target_digest, policy_revision, status,
       decided_by_user_id, expires_at, inserted_at, updated_at)
    SELECT r.id, r.org_id, t.id, r.action, r.target_digest, r.policy_revision,
      CASE r.status WHEN 'requested' THEN 'pending' ELSE r.status END,
      r.decided_by_user_id, r.expires_at, r.inserted_at, r.updated_at
    FROM reviews r JOIN agent_turns t ON t.review_id = r.id AND t.org_id = r.org_id
    WHERE r.action = 'agents.approve'
    """)

    execute("""
    UPDATE agent_turns t SET approval_id = a.id
    FROM agent_approvals a WHERE a.turn_id = t.id AND a.org_id = t.org_id
    """)

    alter table(:agent_turns), do: remove(:review_id)
    alter table(:agent_sessions), do: remove(:source_bundle)

    alter table(:app_deployments) do
      remove :review_id
      remove :policy_revision
    end

    alter table(:app_data_recoveries), do: remove(:review_id)

    execute("""
    UPDATE execution_capabilities SET revoked_at = NOW()
    WHERE revoked_at IS NULL AND actions &&
      ARRAY['reviews.request','reviews.decide','support.subscribe','support.investigate',
            'support.inspect','support.reply','apps.verify_defect']::varchar[]
    """)

    execute("""
    UPDATE workflow_triggers t SET status = 'disabled', updated_at = NOW()
    FROM workflow_graphs g WHERE g.id = t.workflow_graph_id AND t.status = 'enabled'
      AND EXISTS (
      SELECT 1 FROM jsonb_array_elements(COALESCE(g.definition->'nodes','[]'::jsonb)) n
      WHERE n->>'type' IN ('support.investigate','support.reply','reviews.request')
        OR (n->>'type' IN ('agents.publish_branch','apps.deploy')
            AND COALESCE(n->'params','{}'::jsonb) ?| ARRAY['review_id','policy_revision']))
    """)

    execute("""
    UPDATE workflow_graphs g SET status = 'draft', validated_at = NULL, updated_at = NOW()
    WHERE g.status = 'active' AND EXISTS (
      SELECT 1 FROM jsonb_array_elements(COALESCE(g.definition->'nodes','[]'::jsonb)) n
      WHERE n->>'type' IN ('support.investigate','support.reply','reviews.request')
        OR (n->>'type' IN ('agents.publish_branch','apps.deploy')
            AND COALESCE(n->'params','{}'::jsonb) ?| ARRAY['review_id','policy_revision']))
    """)

    # Old reservations must not resume after their product operation is removed
    # or after a provider node returns to its ordinary callback implementation.
    execute("""
    UPDATE workflow_runs r SET status = 'cancelled', completed_at = NOW(),
      owner = NULL, lease_expires_at = NULL, updated_at = NOW(),
      error = '{"reason":"example_workflow_operation_removed"}'::jsonb
    WHERE r.status IN ('created','running') AND (
      EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(r.definition->'nodes','[]'::jsonb)) n
              WHERE n->>'type' IN ('support.investigate','support.reply','reviews.request',
                'agents.codex.run','agents.publish_branch','apps.deploy',
                'github.pull_requests.create','linear.comments.create'))
      OR EXISTS (SELECT 1 FROM workflow_external_operations o WHERE o.run_id = r.id
                 AND o.status <> 'consumed'
                 AND (o.node_type IN ('github.pull_requests.create','linear.comments.create')
                   OR o.resource->>'kind' IN ('publication_review','deployment_review','review',
                                             'support_investigation','support_reply'))))
    """)

    execute("""
    UPDATE workflow_external_operations o SET status = 'consumed', result = NULL,
      error = '{"reason":"example_workflow_operation_removed"}'::jsonb,
      outcome_digest = '81fe6293a7d068ce0fa36487664f66ed3ddcd49f464550fc116284d3a2a676fc',
      completed_at = COALESCE(o.completed_at,NOW()), consumed_at = NOW(), updated_at = NOW()
    FROM workflow_runs r WHERE r.id = o.run_id AND o.status <> 'consumed'
      AND r.status = 'cancelled' AND r.error->>'reason' = 'example_workflow_operation_removed'
    """)

    drop table(:support_cases)
    drop table(:support_subscriptions)
    drop table(:integration_deliveries)
    drop table(:reviews)
  end

  # Rollback restores the old schema and native permission requests. Removed
  # example-domain records are deliberately not recreated.
  def down do
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

    alter table(:reviews), do: add(:target, :map, null: false, default: %{})

    create table(:support_subscriptions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false
      add :created_by_user_id, :string, null: false
      add :app_id, :uuid, null: false
      add :environment_id, :uuid, null: false
      add :connection, :map, null: false
      add :connection_set, :map, null: false, default: %{}
      add :ticket_prefix, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:support_subscriptions, [:org_id, :app_id])
    create unique_index(:support_subscriptions, [:id, :org_id])

    create table(:support_cases, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, :string, null: false

      add :subscription_id,
          references(:support_subscriptions, type: :uuid, with: [org_id: :org_id]),
          null: false

      add :initiator_user_id, :string, null: false
      add :operation_key, :string, null: false
      add :ticket_id, :string, null: false

      add :session_id, references(:agent_sessions, type: :uuid, with: [org_id: :org_id]),
        null: false

      add :deployed_revision, :string
      add :reply, :map
      timestamps(type: :utc_datetime)
    end

    create unique_index(:support_cases, [:org_id, :operation_key])

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

    alter table(:agent_turns), do: add(:review_id, references(:reviews, type: :uuid))
    alter table(:agent_sessions), do: add(:source_bundle, :map, null: false, default: %{})

    alter table(:app_deployments) do
      add :review_id, :uuid
      add :policy_revision, :integer, null: false, default: 1
    end

    alter table(:app_data_recoveries), do: add(:review_id, :uuid)
    flush()

    execute("""
    INSERT INTO reviews
      (id, org_id, requested_by_user_id, operation_key, action, target_digest,
       policy_revision, eligible_approver_ids, expires_at, status, decided_by_user_id,
       target, inserted_at, updated_at)
    SELECT a.id, a.org_id, t.execution_actor_user_id,
      CASE WHEN a.id = t.approval_id AND t.runtime_state->'approval_request'->>'request_id' IS NOT NULL
        THEN 'worker:' || t.id::text || ':' || (t.runtime_state->'approval_request'->>'request_id')
        ELSE 'approval:' || a.id::text END,
      a.action, a.target_digest, a.policy_revision, ARRAY[t.execution_actor_user_id],
      a.expires_at, CASE a.status WHEN 'pending' THEN 'requested' ELSE a.status END,
      a.decided_by_user_id, CASE WHEN a.id = t.approval_id
        THEN COALESCE(t.runtime_state->'approval_request','{}'::jsonb) ELSE '{}'::jsonb END,
      a.inserted_at, a.updated_at
    FROM agent_approvals a JOIN agent_turns t ON t.id = a.turn_id AND t.org_id = a.org_id
    """)

    execute("""
    UPDATE agent_turns t SET review_id = a.id
    FROM agent_approvals a WHERE a.id = t.approval_id AND a.org_id = t.org_id
    """)

    alter table(:agent_turns) do
      remove :approval_id
      remove :verification_commands
    end

    drop table(:agent_approvals)
  end
end
