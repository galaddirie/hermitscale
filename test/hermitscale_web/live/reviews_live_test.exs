defmodule HermitscaleWeb.ReviewsLiveTest do
  use HermitscaleWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import HermitscaleWeb.BrowserAuthFixtures

  import Hermitscale.ProductFixtures,
    only: [review_fixture: 1, review_fixture: 2, expire_fixture: 1]

  alias Hermitscale.{Artifacts, AuthTest.Provider, Reviews}

  setup %{conn: conn} do
    setup_provider()
    authenticated_conn(conn)
  end

  test "the review inbox requires sign-in and exposes concrete pending requests", %{
    conn: conn,
    scope: scope
  } do
    assert {:error, {:redirect, %{to: "/auth/login"}}} =
             conn |> clear_session() |> live(~p"/reviews")

    review = review_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/reviews")
    assert has_element?(view, "#review-#{review.id}")
    assert has_element?(view, "#refresh-reviews")

    assert has_element?(view, "#review-list[phx-update='stream']")
  end

  test "the detail records an approval over the displayed exact target", %{
    conn: conn,
    scope: scope
  } do
    review = review_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/reviews/#{review.id}")
    assert has_element?(view, "#review-target", "fix/ENG-7")
    assert has_element?(view, "#review-proof", review.target_digest)
    assert has_element?(view, "#approve-review:not([disabled])")
    view |> element("#approve-review") |> render_click()
    assert {:ok, approved} = Reviews.get(scope, review.id)
    assert approved.status == :approved
    assert has_element?(view, "#review-status", "Approved")
    assert has_element?(view, "#review-decision-message[role='status']")
    refute has_element?(view, "#approve-review")
  end

  test "late notifications for another review preserve the current detail", %{
    conn: conn,
    scope: scope
  } do
    current = review_fixture(scope)
    previous = review_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/reviews/#{current.id}")
    send(view.pid, {:review_updated, previous.id})
    assert has_element?(view, "#review-proof", current.target_digest)
    assert has_element?(view, "#approve-review:not([disabled])")
  end

  test "rejection is retained and cannot be overwritten by a forged second decision", %{
    conn: conn,
    scope: scope
  } do
    review = review_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/reviews/#{review.id}")
    view |> element("#reject-review") |> render_click()
    assert has_element?(view, "#review-status", "Rejected")
    render_click(view, "decide", %{"decision" => "approved"})
    assert {:ok, rejected} = Reviews.get(scope, review.id)
    assert rejected.status == :rejected
    assert has_element?(view, "#flash-error")
  end

  test "an approved review reloads its exact target without offering another decision", %{
    conn: conn,
    scope: scope
  } do
    review = review_fixture(scope)
    assert {:ok, _approved} = Reviews.decide(scope, review.id, :approved)
    {:ok, view, _html} = live(conn, ~p"/reviews/#{review.id}")
    assert has_element?(view, "#review-target", "fix/ENG-7")
    assert has_element?(view, "#review-proof", review.target_digest)
    assert has_element?(view, "#review-status", "Approved")
    refute has_element?(view, "#approve-review")
    refute has_element?(view, "#reject-review")
  end

  test "a current read-only role can inspect the request but cannot decide", %{
    conn: conn,
    scope: scope
  } do
    review = review_fixture(scope)
    :ok = Provider.put_response(:get_role, {:ok, %{permissions: ["reviews:read"]}})
    {:ok, view, _html} = live(conn, ~p"/reviews/#{review.id}")
    assert has_element?(view, "#review-proof", review.target_digest)
    assert has_element?(view, "#approve-review[disabled]")
    render_click(view, "decide", %{"decision" => "approved"})
    assert {:ok, %{status: :requested}} = Reviews.get(scope, review.id)
    assert has_element?(view, "#flash-error")
  end

  test "expired and ineligible requests keep decisions disabled", %{conn: conn, scope: scope} do
    expired = review_fixture(scope) |> expire_fixture()
    {:ok, view, _html} = live(conn, ~p"/reviews/#{expired.id}")
    assert has_element?(view, "#approve-review[disabled]")
    assert has_element?(view, "#review-status", "Expired")
    render_click(view, "decide", %{"decision" => "approved"})
    assert {:ok, %{status: :requested}} = Reviews.get(scope, expired.id)
    ineligible = review_fixture(scope, eligible_approver_ids: ["another-reviewer"])
    {:ok, other_view, _html} = live(conn, ~p"/reviews/#{ineligible.id}")
    assert has_element?(other_view, "#reject-review[disabled]")
  end

  test "revoked authority blocks a decision after the page was opened", %{
    conn: conn,
    scope: scope
  } do
    review = review_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/reviews/#{review.id}")
    :ok = Provider.remove_membership("membership:owner")
    view |> element("#approve-review") |> render_click()
    assert {:ok, %{status: :requested}} = Reviews.get(scope, review.id)
    assert has_element?(view, "#flash-error", "current role")
  end

  test "recorded patch evidence is displayed and can be downloaded without waking compute", %{
    conn: conn,
    scope: scope
  } do
    session =
      HermitscaleWeb.AgentFixtures.conversation_fixture(scope, %{
        repository: "acme/backend",
        base_sha: String.duplicate("a", 40)
      })

    snapshot = %{
      "base_sha" => String.duplicate("a", 40),
      "diff" => "diff --git a/lib/fix.ex b/lib/fix.ex\n+verified change",
      "files" => []
    }

    {:ok, artifact} =
      Artifacts.record(scope, %{
        owner_type: "session",
        owner_id: session.id,
        kind: "patch_snapshot",
        content_type: "application/json",
        content: Jason.encode!(snapshot)
      })

    target = %{"patch_snapshot_artifact_id" => artifact.id, "manifest" => ["lib/fix.ex"]}

    review =
      review_fixture(scope,
        target: target,
        target_digest: Hermitscale.Agents.Protocol.payload_digest(target)
      )

    {:ok, view, _html} = live(conn, ~p"/reviews/#{review.id}")
    assert has_element?(view, "#review-patch", "diff --git")
    assert has_element?(view, "#review-artifact-download[href='/artifacts/#{artifact.id}']")
    assert has_element?(view, "#approve-review:not([disabled])")
  end

  test "a designated reviewer can read only the bound patch without conversation permissions", %{
    conn: conn,
    scope: scope,
    authentication: authentication
  } do
    session =
      HermitscaleWeb.AgentFixtures.conversation_fixture(scope, %{
        repository: "acme/backend",
        base_sha: String.duplicate("a", 40)
      })

    {:ok, exported} =
      Artifacts.record(scope, %{
        owner_type: "session",
        owner_id: session.id,
        kind: "workspace_file",
        content_type: "application/octet-stream",
        content: "Private new file bytes"
      })

    snapshot = %{
      "base_sha" => session.base_sha,
      "diff" => "The reviewed change",
      "files" => [],
      "exports" =>
        Enum.map(["lib/new.ex", "lib/copy.ex"], fn path ->
          %{"path" => path, "artifact_id" => exported.id, "digest" => exported.digest}
        end)
    }

    {:ok, patch} =
      Artifacts.record(scope, %{
        owner_type: "session",
        owner_id: session.id,
        kind: "patch_snapshot",
        content_type: "application/json",
        content: Jason.encode!(snapshot)
      })

    {:ok, unbound} =
      Artifacts.record(scope, %{
        owner_type: "session",
        owner_id: session.id,
        kind: "patch_snapshot",
        content_type: "application/json",
        content: Jason.encode!(%{"diff" => "Unrelated private evidence"})
      })

    target = %{
      "session_id" => session.id,
      "base_sha" => session.base_sha,
      "branch" => "fix/ENG-7",
      "message" => "Apply reviewed changes",
      "patch_snapshot_artifact_id" => patch.id,
      "manifest" => ["lib/fix.ex"],
      "candidate_digest" =>
        Hermitscale.Agents.Protocol.payload_digest(Map.take(snapshot, ~w(base_sha diff files))),
      "policy_revision" => 1
    }

    {:ok, digest} = Hermitscale.Agents.Publications.target_digest(scope, session.id, target)

    review =
      review_fixture(scope,
        target: target,
        action: "agents.publish_branch",
        target_digest: digest,
        eligible_approver_ids: ["colleague"]
      )

    {:ok, membership} = Provider.update_membership("membership:colleague", "admin")
    permissions = ["reviews:read", "reviews:decide"]

    reviewer =
      Hermitscale.Accounts.Scope.for_user(%{id: "colleague", email: "reviewer@example.test"})
      |> Hermitscale.Accounts.Scope.put_organization(
        scope.organization,
        Map.put(membership, :permissions, permissions)
      )

    :ok = Provider.put_response(:get_role, {:ok, %{permissions: permissions}})
    :ok = Provider.put_response(:authenticate, {:ok, %{authentication | current_scope: reviewer}})
    {:ok, view, _html} = live(conn, ~p"/reviews/#{review.id}")
    assert has_element?(view, "#review-patch", "The reviewed change")
    assert has_element?(view, "#review-exports[phx-update='stream']")

    for path <- ["lib/new.ex", "lib/copy.ex"] do
      assert has_element?(
               view,
               "#review-exports a[data-export-path='#{path}'][href='/artifacts/#{exported.id}']",
               exported.digest
             )
    end

    refute has_element?(view, "#review-exports", "Private new file bytes")
    assert {:ok, %{id: exported_id}} = Artifacts.get(reviewer, exported.id)
    assert exported_id == exported.id
    assert has_element?(view, "#approve-review:not([disabled])")
    assert {:ok, %{id: id}} = Artifacts.get(reviewer, patch.id)
    assert id == patch.id
    assert {:error, :not_found} = Artifacts.get(reviewer, unbound.id)
    assert {:error, :forbidden} = Hermitscale.Agents.get_session(reviewer, session.id)
  end
end
