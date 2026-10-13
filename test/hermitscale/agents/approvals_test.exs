defmodule Hermitscale.Agents.ApprovalsTest do
  use Hermitscale.DataCase, async: false
  import Hermitscale.ProductFixtures
  import Hermitscale.AgentsFixtures
  alias Hermitscale.Agents.{Approvals, Protocol}
  alias Hermitscale.AuthTest.Provider

  setup do
    %{current_scope: scope} = authenticated_product_fixture()
    session = agent_session_fixture(scope)
    turn = agent_turn_fixture(scope, session)

    digest =
      Protocol.payload_digest(%{"request_id" => "provider-request", "command" => "mix test"})

    attrs = %{action: "agents.approve", target_digest: digest, policy_revision: 1}
    %{scope: scope, turn: turn, digest: digest, attrs: attrs}
  end

  test "the owning actor answers one exact native permission request", context do
    %{scope: scope, turn: turn, digest: digest, attrs: attrs} = context
    assert {:ok, approval} = Approvals.request(scope, turn.id, attrs)
    assert approval.status == :pending
    assert approval.expires_at == turn.deadline
    assert {:ok, same} = Approvals.request(scope, turn.id, attrs)
    assert same.id == approval.id

    turn
    |> Ecto.Changeset.change(status: :waiting_for_approval, approval_id: approval.id)
    |> Repo.update!()

    assert {:ok, approved} = Approvals.decide(scope, approval.id, :approved)
    assert approved.decided_by_user_id == scope.user.id
    assert :ok = Approvals.authorize_decision(scope, approval.id, "agents.approve", digest, 1)
    assert {:ok, ^approved} = Approvals.decide(scope, approval.id, :approved)
    assert {:error, :approval_already_decided} = Approvals.decide(scope, approval.id, :rejected)

    assert {:error, :approval_mismatch_or_not_approved} =
             Approvals.authorize_decision(
               scope,
               approval.id,
               "agents.approve",
               String.duplicate("b", 64),
               1
             )
  end

  test "an existing native decision remains bound to its original permission ID", context do
    %{scope: scope, turn: turn, attrs: attrs} = context

    retained =
      %Hermitscale.Agents.Approval{
        id: Ecto.UUID.generate(),
        org_id: turn.org_id,
        turn_id: turn.id,
        expires_at: turn.deadline
      }
      |> Hermitscale.Agents.Approval.changeset(attrs)
      |> Repo.insert!()

    turn |> Ecto.Changeset.change(approval_id: retained.id) |> Repo.update!()
    assert {:ok, same} = Approvals.request(scope, turn.id, attrs)
    assert same.id == retained.id
  end

  test "invalid native permission attributes are rejected before persistence", context do
    %{scope: scope, turn: turn, attrs: attrs} = context

    assert {:error, %Ecto.Changeset{valid?: false}} =
             Approvals.request(scope, turn.id, Map.put(attrs, :action, "apps.deploy"))

    assert {:error, %Ecto.Changeset{valid?: false}} =
             Approvals.request(scope, turn.id, Map.put(attrs, :target_digest, "invalid"))
  end

  test "permission decisions cannot resume a stale or expired turn", context do
    %{scope: scope, turn: turn, attrs: attrs} = context
    assert {:ok, approval} = Approvals.request(scope, turn.id, attrs)
    assert {:error, :stale_approval} = Approvals.decide(scope, approval.id, :approved)

    turn
    |> Ecto.Changeset.change(status: :waiting_for_approval, approval_id: approval.id)
    |> Repo.update!()

    approval
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1))
    |> Repo.update!()

    assert {:error, :approval_expired} = Approvals.decide(scope, approval.id, :approved)
  end

  test "current execution permission is required even with an existing browser scope", context do
    %{scope: scope, turn: turn, attrs: attrs} = context
    assert {:ok, approval} = Approvals.request(scope, turn.id, attrs)

    turn
    |> Ecto.Changeset.change(status: :waiting_for_approval, approval_id: approval.id)
    |> Repo.update!()

    :ok = Provider.put_response(:get_role, {:ok, %{permissions: ["agents:read"]}})
    assert {:error, :execution_actor_ineligible} = Approvals.decide(scope, approval.id, :approved)
  end

  test "another organization cannot inspect or answer a native permission", context do
    %{scope: scope, turn: turn, attrs: attrs} = context
    assert {:ok, approval} = Approvals.request(scope, turn.id, attrs)
    other = Hermitscale.AccountsFixtures.organization_scope_fixture()

    other = %{
      other
      | membership: %{other.membership | permissions: ["agents:read", "agents:run"]}
    }

    assert {:error, _reason} = Approvals.get(other, approval.id)
  end
end
