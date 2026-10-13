defmodule Hermitscale.ReviewsTest do
  use Hermitscale.DataCase, async: false
  import Hermitscale.ProductFixtures
  alias Hermitscale.{AuthTest.Provider, Reviews}

  setup do
    authentication = authenticated_product_fixture()
    %{scope: authentication.current_scope}
  end

  test "a decision authorizes only its exact action, digest and policy revision", %{scope: scope} do
    review = review_fixture(scope)

    assert {:error, :review_mismatch_or_not_approved} =
             Reviews.authorize_decision(scope, review.id, review.action, review.target_digest, 1)

    assert {:ok, approved} = Reviews.decide(scope, review.id, :approved)
    assert approved.decided_by_user_id == scope.user.id

    assert :ok =
             Reviews.authorize_decision(scope, review.id, review.action, review.target_digest, 1)

    assert {:error, :review_mismatch_or_not_approved} =
             Reviews.authorize_decision(scope, review.id, "apps.deploy", review.target_digest, 1)

    assert {:error, :review_mismatch_or_not_approved} =
             Reviews.authorize_decision(
               scope,
               review.id,
               review.action,
               String.duplicate("b", 64),
               1
             )

    assert {:error, :review_mismatch_or_not_approved} =
             Reviews.authorize_decision(scope, review.id, review.action, review.target_digest, 2)

    assert {:ok, same} = Reviews.decide(scope, review.id, :approved)
    assert same.decided_at == approved.decided_at
    assert {:error, :review_already_decided} = Reviews.decide(scope, review.id, :rejected)
  end

  test "expired approvals cannot be decided or used", %{scope: scope} do
    undecided = review_fixture(scope) |> expire_fixture()
    assert {:error, :review_expired} = Reviews.decide(scope, undecided.id, :approved)
    approved = review_fixture(scope)
    {:ok, approved} = Reviews.decide(scope, approved.id, :approved)
    approved = expire_fixture(approved)

    assert {:error, :review_expired} =
             Reviews.authorize_decision(
               scope,
               approved.id,
               approved.action,
               approved.target_digest,
               approved.policy_revision
             )
  end

  test "revocation after approval invalidates the approver's authority", %{scope: scope} do
    review = review_fixture(scope)
    {:ok, _approved} = Reviews.decide(scope, review.id, :approved)
    :ok = Provider.remove_membership("membership:owner")

    assert {:error, :execution_actor_ineligible} =
             Reviews.authorize_decision(scope, review.id, review.action, review.target_digest, 1)
  end

  test "only eligible current approvers can decide and foreign tenants cannot read", %{
    scope: scope
  } do
    review = review_fixture(scope, eligible_approver_ids: ["different-person"])
    assert {:error, :ineligible_approver} = Reviews.decide(scope, review.id, :approved)
    foreign = Hermitscale.AccountsFixtures.organization_scope_fixture()
    foreign = %{foreign | membership: %{foreign.membership | permissions: ["reviews:read"]}}
    assert {:error, :not_found} = Reviews.get(foreign, review.id)
    denied = %{scope | membership: %{scope.membership | permissions: []}}
    assert {:error, :forbidden} = Reviews.request(denied, review_attrs_fixture())
    assert {:error, :forbidden} = Reviews.decide(denied, review.id, :approved)
  end

  test "reused admission keys cannot change the reviewed intent", %{scope: scope} do
    attrs = review_attrs_fixture()
    {:ok, first} = Reviews.request(scope, attrs)
    assert {:ok, duplicate} = Reviews.request(scope, attrs)
    assert duplicate.id == first.id

    changed_target = Map.put(attrs.target, "branch", "fix/ENG-8")
    changed_digest = Hermitscale.Agents.Protocol.payload_digest(changed_target)

    assert {:error, :review_key_conflict} =
             Reviews.request(scope, %{
               attrs
               | target_digest: changed_digest,
                 target: changed_target
             })

    assert {:error, :invalid_review_expiry} =
             Reviews.request(scope, Map.put(attrs, :expiry_seconds, 0))

    assert {:error, :review_target_mismatch} =
             Reviews.request(scope, %{attrs | target_digest: "not-a-digest"})
  end

  test "requesting arbitrary reviews cannot grant access to another actor's private patch", %{
    scope: scope
  } do
    session = Hermitscale.AgentsFixtures.agent_session_fixture(scope)

    {:ok, artifact} =
      Hermitscale.Artifacts.record(scope, %{
        owner_type: "session",
        owner_id: session.id,
        kind: "patch_snapshot",
        content_type: "application/json",
        content:
          Jason.encode!(%{
            "base_sha" => session.base_sha,
            "diff" => "Private patch",
            "files" => []
          })
      })

    {:ok, membership} = Provider.update_membership("membership:colleague", "admin")

    attacker =
      Hermitscale.Accounts.Scope.for_user(%{id: "colleague"})
      |> Hermitscale.Accounts.Scope.put_organization(
        scope.organization,
        Map.put(
          membership,
          :permissions,
          Hermitscale.AccountsFixtures.role_permissions_fixture("admin")
        )
      )

    target = %{"session_id" => session.id, "patch_snapshot_artifact_id" => artifact.id}

    for action <- ["arbitrary.approval", "agents.approve"] do
      assert {:ok, _review} =
               Reviews.request(attacker, %{
                 action: action,
                 target: target,
                 target_digest: Hermitscale.Agents.Protocol.payload_digest(target),
                 operation_key: Ecto.UUID.generate()
               })

      assert {:error, :not_found} = Hermitscale.Artifacts.get(attacker, artifact.id)
    end

    assert {:error, :not_found} = Hermitscale.Agents.get_session(attacker, session.id)
  end

  test "a reviewed snapshot cannot grant another session's exported file", %{scope: scope} do
    victim_session = Hermitscale.AgentsFixtures.agent_session_fixture(scope)

    {:ok, private_file} =
      Hermitscale.Artifacts.record(scope, %{
        owner_type: "session",
        owner_id: victim_session.id,
        kind: "workspace_file",
        content_type: "application/octet-stream",
        content: "Other actor's private file"
      })

    {:ok, membership} = Provider.update_membership("membership:colleague", "admin")

    attacker =
      Hermitscale.Accounts.Scope.for_user(%{id: "colleague"})
      |> Hermitscale.Accounts.Scope.put_organization(
        scope.organization,
        Map.put(
          membership,
          :permissions,
          Hermitscale.AccountsFixtures.role_permissions_fixture("admin")
        )
      )

    owned_session = Hermitscale.AgentsFixtures.agent_session_fixture(attacker)

    snapshot = %{
      "base_sha" => owned_session.base_sha,
      "diff" => "Own recorded change",
      "files" => [],
      "exports" => [
        %{
          "path" => "lib/private.ex",
          "artifact_id" => private_file.id,
          "digest" => private_file.digest
        }
      ]
    }

    {:ok, patch} =
      Hermitscale.Artifacts.record(attacker, %{
        owner_type: "session",
        owner_id: owned_session.id,
        kind: "patch_snapshot",
        content_type: "application/json",
        content: Jason.encode!(snapshot)
      })

    target = %{
      "session_id" => owned_session.id,
      "base_sha" => owned_session.base_sha,
      "branch" => "fix/owned-change",
      "manifest" => ["lib/private.ex"],
      "message" => "Own reviewed change",
      "patch_snapshot_artifact_id" => patch.id,
      "candidate_digest" =>
        Hermitscale.Agents.Protocol.payload_digest(Map.take(snapshot, ~w(base_sha diff files))),
      "policy_revision" => 1
    }

    {:ok, digest} =
      Hermitscale.Agents.Publications.target_digest(attacker, owned_session.id, target)

    assert {:ok, _review} =
             Reviews.request(attacker, %{
               action: "agents.publish_branch",
               target: target,
               target_digest: digest,
               eligible_approver_ids: [attacker.user.id],
               operation_key: Ecto.UUID.generate()
             })

    assert {:ok, %{id: id}} = Hermitscale.Artifacts.get(attacker, patch.id)
    assert id == patch.id
    assert {:error, :not_found} = Hermitscale.Artifacts.get(attacker, private_file.id)
  end
end
