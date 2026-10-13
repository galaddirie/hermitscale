defmodule Hermitscale.Agents.PublicationsTest do
  use Hermitscale.DataCase, async: false
  use Oban.Testing, repo: Hermitscale.Repo
  import Hermitscale.ProductFixtures
  import Hermitscale.AgentsFixtures
  import Hermitscale.IntegrationsFixtures
  alias Hermitscale.{Agents, AgentsRuntimeFake, Artifacts, AuthTest.Provider}
  alias Hermitscale.Agents.{Publications, PublicationWorker}
  alias Hermitscale.WorkOSTest.Client, as: Pipes

  setup do
    %{current_scope: scope} = authenticated_product_fixture()
    configure_product_fixture(Hermitscale.Agents.Runtime, adapter: AgentsRuntimeFake)
    configure_product_fixture(:workspace_management_adapter, AgentsRuntimeFake)
    session = agent_session_fixture(scope)
    start_supervised!({AgentsRuntimeFake, outcomes: [success(session)]})
    turn = agent_turn_fixture(scope, session)
    {:ok, completed} = Agents.reconcile_turn(scope, turn.id)
    result = completed.result

    target = %{
      "session_id" => session.id,
      "branch" => "fix/ENG-7",
      "message" => "Fix the reported defect",
      "base_sha" => result["base_sha"],
      "manifest" => result["manifest"],
      "candidate_digest" => result["candidate_digest"],
      "patch_snapshot_artifact_id" => result["patch_snapshot_artifact_id"],
      "operation_key" => Ecto.UUID.generate()
    }

    %{scope: scope, session: session, target: target}
  end

  test "host-recorded patch snapshot binds idempotent publication without a review",
       context do
    %{scope: scope, session: session, target: target} = context
    assert {:ok, digest} = Publications.target_digest(scope, session.id, target)
    assert {:ok, artifact} = Artifacts.get(scope, target["patch_snapshot_artifact_id"])
    assert artifact.owner_id == session.id
    assert artifact.kind == "patch_snapshot"
    assert {:ok, publication} = Agents.publish_branch(scope, session.id, target)
    assert publication.status == :queued
    assert publication.payload_digest == digest
    assert_enqueued(worker: PublicationWorker, args: %{publication_id: publication.id})
    assert {:ok, same} = Agents.publish_branch(scope, session.id, target)
    assert same.id == publication.id
    assert length(AgentsRuntimeFake.steps()) == 1
  end

  test "changed publication intent cannot reuse a key and invalid source evidence is refused",
       context do
    %{scope: scope, session: session, target: target} = context
    assert {:ok, _publication} = Agents.publish_branch(scope, session.id, target)

    for changed <- [
          Map.put(target, "manifest", ["lib/other.ex"]),
          Map.put(target, "branch", "fix/ENG-8")
        ] do
      assert {:error, :publication_key_conflict} =
               Agents.publish_branch(scope, session.id, changed)
    end

    for changed <- [
          Map.put(target, "candidate_digest", String.duplicate("b", 64)),
          Map.put(target, "base_sha", String.duplicate("b", 40))
        ] do
      assert {:error, :publication_evidence_mismatch} =
               Agents.publish_branch(scope, session.id, changed)
    end

    assert_enqueued(worker: PublicationWorker)
  end

  test "artifacts from another private session or a raw diff are not publication snapshots",
       context do
    %{scope: scope, session: session, target: target} = context
    {:ok, original} = Artifacts.get(scope, target["patch_snapshot_artifact_id"])
    other = agent_session_fixture(scope)

    {:ok, foreign} =
      Artifacts.record(scope, %{
        owner_type: "session",
        owner_id: other.id,
        kind: "patch_snapshot",
        content_type: "application/json",
        content: original.content
      })

    {:ok, diff} =
      Artifacts.record(scope, %{
        owner_type: "session",
        owner_id: session.id,
        kind: "patch",
        content_type: "text/plain",
        content: "verified diff"
      })

    for artifact <- [foreign, diff] do
      assert {:error, :publication_evidence_mismatch} =
               Publications.target_digest(
                 scope,
                 session.id,
                 Map.put(target, "patch_snapshot_artifact_id", artifact.id)
               )
    end

    refute_enqueued(worker: PublicationWorker)
  end

  test "current publish revocation blocks snapshot publication", context do
    %{scope: scope, session: session, target: target} = context
    :ok = Provider.put_response(:get_role, {:ok, %{permissions: ["agents:read"]}})

    assert {:error, :execution_actor_ineligible} =
             Agents.publish_branch(scope, session.id, target)

    refute_enqueued(worker: PublicationWorker)
  end

  test "a committed result and writer release recover without another publication command",
       context do
    %{scope: scope, session: session, target: target} = context
    publication = admit_publication(context)
    outcome = publication_result(context)
    install_publication_runtime(scope, [{Jason.encode!(outcome), 0}], fail_stop: true)
    assert :ok = Agents.subscribe(scope, session.id)
    assert {:ok, pending} = Publications.reconcile(scope, publication.id)
    assert pending.status == :uncertain
    assert pending.result["commit_sha"] == outcome["commit_sha"]
    assert pending.result["repository"] == session.repository
    assert {:ok, %{status: :active}} = Hermitscale.Workspaces.get_lease(scope, pending.lease_id)
    assert {:ok, completed} = Publications.reconcile(scope, publication.id)
    assert completed.status == :succeeded

    assert {:ok, %{status: :released}} =
             Hermitscale.Workspaces.get_lease(scope, completed.lease_id)

    assert length(Hermitscale.PublicationSDKFake.requests()) == 1
    assert_receive {:agent_session_updated, id}
    assert id == session.id
    assert [^completed] = Publications.list_for_session(scope, session.id)
    assert {:ok, sha} = Publications.current_base_sha(scope, session.id)
    assert sha == outcome["commit_sha"]
    assert {:ok, unchanged} = Agents.get_session(scope, session.id)
    assert unchanged.base_sha == session.base_sha
    completed |> Ecto.Changeset.change(status: :running) |> Repo.update!()
    assert {:ok, ^sha} = Publications.current_base_sha(scope, session.id)
    assert {:ok, %{status: :succeeded}} = Publications.reconcile(scope, completed.id)
    assert length(Hermitscale.PublicationSDKFake.requests()) == 1

    assert {:ok, same} =
             Agents.publish_branch(scope, session.id, target)

    assert same.id == completed.id
    assert same.status == :succeeded
  end

  test "known candidate refusal fails after independently releasing the admitted writer",
       context do
    %{scope: scope} = context
    publication = admit_publication(context)
    install_publication_runtime(scope, [{"", 86}])
    assert {:ok, failed} = Publications.reconcile(scope, publication.id)
    assert failed.status == :failed
    assert failed.error["reason"] == ":candidate_changed"
    assert {:ok, %{status: :released}} = Hermitscale.Workspaces.get_lease(scope, failed.lease_id)
    assert {:ok, ^failed} = Publications.reconcile(scope, publication.id)
    assert length(Hermitscale.PublicationSDKFake.requests()) == 1
  end

  test "an expired uncertain effect uses read-only marker reconciliation and never new publication",
       context do
    %{scope: scope} = context
    publication = admit_publication(context)
    outcome = publication_result(context)
    install_publication_runtime(scope, [{"", 84}, {Jason.encode!(outcome), 0}])
    assert {:ok, pending} = Publications.reconcile(scope, publication.id)
    assert pending.status == :uncertain

    pending
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(:second), -301))
    |> Repo.update!()

    assert {:ok, completed} = Publications.reconcile(scope, pending.id)
    assert completed.status == :succeeded
    assert [first, second] = Hermitscale.PublicationSDKFake.requests()
    assert first["reconcile_only"] == false
    assert second["reconcile_only"] == true
    assert first["operation_id"] == second["operation_id"]
    assert first["lease_id"] == second["lease_id"]
  end

  test "revoked execution authority stops its admitted writer while retaining uncertainty",
       context do
    %{scope: scope} = context
    publication = admit_publication(context)
    install_publication_runtime(scope, [{"", 84}])
    assert {:ok, pending} = Publications.reconcile(scope, publication.id)
    calls = Pipes.calls()
    :ok = Provider.remove_membership("membership:owner")

    assert {:cancel, "execution_actor_ineligible"} =
             PublicationWorker.perform(%Oban.Job{
               args: %{"publication_id" => pending.id},
               attempt: 1,
               max_attempts: 5
             })

    retained = Repo.get!(Hermitscale.Agents.Publication, pending.id)
    assert retained.status == :uncertain
    assert retained.error["reconciliation_only"] == true
    assert Repo.get!(Hermitscale.Workspaces.Lease, retained.lease_id).status == :released
    assert Pipes.calls() == calls
    assert length(Hermitscale.PublicationSDKFake.requests()) == 1
  end

  test "the final retry stops the writer and later requests can only reconcile the retained marker",
       context do
    %{scope: scope} = context
    publication = admit_publication(context)

    install_publication_runtime(scope, [
      {"", 84},
      {"", 84},
      {Jason.encode!(publication_result(context)), 0}
    ])

    assert {:ok, pending} = Publications.reconcile(scope, publication.id)

    assert {:cancel, "reconciliation_attempts_exhausted"} =
             PublicationWorker.perform(%Oban.Job{
               args: %{"publication_id" => pending.id},
               attempt: 5,
               max_attempts: 5
             })

    assert Repo.get!(Hermitscale.Workspaces.Lease, pending.lease_id).status == :released
    assert {:ok, completed} = Publications.reconcile(scope, pending.id)
    assert completed.status == :succeeded

    assert Enum.map(Hermitscale.PublicationSDKFake.requests(), & &1["reconcile_only"]) == [
             false,
             false,
             true
           ]
  end

  test "a stopped local commit advances the private baseline while its remote publication stays uncertain",
       context do
    %{scope: scope, session: session} = context
    publication = admit_publication(context)
    sha = String.duplicate("c", 40)
    receipt = %{"local_commit" => sha, "base_sha" => sha, "verified" => false}
    install_publication_runtime(scope, [{Jason.encode!(receipt), 84}, {"", 84}])

    assert {:ok, pending} = Publications.reconcile(scope, publication.id)
    assert pending.status == :uncertain
    assert pending.result == nil
    assert pending.error["local_receipt"] == receipt
    assert {:ok, initial_base} = Publications.current_base_sha(scope, session.id)
    assert initial_base == session.base_sha

    assert {:ok, stopped} =
             Publications.terminate(pending.id, "reconciliation_attempts_exhausted")

    assert stopped.status == :uncertain
    assert stopped.result == nil
    assert stopped.error["reconciliation_only"] == true
    assert stopped.error["local_receipt"] == receipt
    assert {:ok, ^sha} = Publications.current_base_sha(scope, session.id)

    assert {:ok, retained} = Publications.reconcile(scope, stopped.id)
    assert retained.status == :uncertain
    assert retained.result == nil
    assert retained.error["local_receipt"] == receipt
    assert {:ok, ^sha} = Publications.current_base_sha(scope, session.id)

    assert Enum.map(Hermitscale.PublicationSDKFake.requests(), & &1["reconcile_only"]) == [
             false,
             true
           ]
  end

  defp admit_publication(%{scope: scope, session: session, target: target}) do
    {:ok, publication} = Agents.publish_branch(scope, session.id, target)

    publication
  end

  defp publication_result(%{session: session, target: target}),
    do: %{
      "repository" => "github:" <> session.repository,
      "branch" => target["branch"],
      "base_sha" => target["base_sha"],
      "manifest" => target["manifest"],
      "commit_sha" => String.duplicate("b", 40),
      "verified" => true
    }

  defp install_publication_runtime(scope, responses, options \\ []) do
    start_supervised!({Hermitscale.PublicationRuntimeFake, options})
    start_supervised!({Hermitscale.PublicationSDKFake, responses: responses})
    start_supervised!({Pipes, %{}})
    configure_product_fixture(:workspace_management_adapter, Hermitscale.PublicationRuntimeFake)
    configure_product_fixture(:sprites_sdk, Hermitscale.PublicationSDKFake)

    configure_product_fixture(Hermitscale.Workspaces.SpritesManagement,
      token: "private-sprite-fixture"
    )

    Pipes.put_response(
      :list_org_providers,
      {:ok,
       %{
         "data" => [
           %{
             "slug" => "github",
             "connected_accounts" => [account_fixture("github", scope.organization.id)]
           }
         ]
       }}
    )

    Pipes.put_response(
      :vend_credentials,
      {:ok,
       %{
         auth_method: "oauth",
         value: "private-github-fixture",
         scopes: scopes_fixture("github"),
         missing_scopes: []
       }}
    )
  end

  defp success(session),
    do: %{
      status: :succeeded,
      worker_state: %{
        "provider_session_id" => "publication-thread",
        "termination_confirmed" => true
      },
      result: %{
        "base_sha" => session.base_sha,
        "head_sha" => session.base_sha,
        "diff" => "verified diff",
        "checks" => [%{"name" => "repository tests", "exit_code" => 0}],
        "manifest" => ["lib/fix.ex"],
        "files" => [],
        "result" => %{}
      }
    }
end
