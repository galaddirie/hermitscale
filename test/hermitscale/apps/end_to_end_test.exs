defmodule Hermitscale.Apps.EndToEndTest do
  use Hermitscale.DataCase, async: false
  use Oban.Testing, repo: Hermitscale.Repo
  import Hermitscale.AppsFixtures
  alias Hermitscale.{Agents, Apps, Artifacts, Auth, Workspaces}
  alias Hermitscale.Apps.{RecoveryWorker, ReleaseWorker}
  alias Hermitscale.AppsRuntimeFake, as: Remote

  setup do
    scope = app_scope_fixture()
    provider = Hermitscale.AuthTest.Provider
    previous = Application.fetch_env!(:hermitscale, Auth)
    previous_management = Application.get_env(:hermitscale, :workspace_management_adapter)
    previous_access = Application.get_env(:hermitscale, :workspace_access_adapter)
    previous_apps = Application.get_env(:hermitscale, Apps)

    start_supervised!(
      {provider,
       %{
         user: scope.user,
         organizations: %{scope.organization.id => scope.organization},
         memberships: %{
           "app-owner" => Map.merge(scope.membership, %{id: "app-owner", status: "active"})
         }
       }}
    )

    start_supervised!({Remote, []})
    Application.put_env(:hermitscale, Auth, provider: provider)
    Application.put_env(:hermitscale, :workspace_management_adapter, Remote)
    Application.put_env(:hermitscale, :workspace_access_adapter, Remote)
    Application.put_env(:hermitscale, Apps, gateway_host: "apps.example.test")

    on_exit(fn ->
      Application.put_env(:hermitscale, Auth, previous)
      restore(:workspace_management_adapter, previous_management)
      restore(:workspace_access_adapter, previous_access)
      restore(Apps, previous_apps)
    end)

    app = app_fixture(scope)
    session = app_build_fixture(scope, app)
    %{scope: scope, app: app, session: session}
  end

  test "registry, environment and conversation history do not allocate compute", %{
    scope: scope,
    app: app,
    session: session
  } do
    assert [record] = Apps.list_apps(scope)
    assert record.id == app.id
    assert [environment] = Apps.list_environments(scope, app.id)
    assert environment.active_deployment_id == nil
    assert {:ok, workspace} = Workspaces.get_workspace(scope, environment.workspace_id)
    assert workspace.recipe == "python-sqlite-v1"
    assert workspace.resource_state == :provision_pending
    assert Apps.read_logs(scope, app.id) == []
    assert Agents.list_turns(scope, session.id) == []
    assert Remote.calls() == []

    assert {:ok, same} =
             Apps.start_build(scope, app.id, %{
               operation_key: hd(Apps.list_build_sessions(scope, app.id)).operation_key
             })

    assert same.id == session.id

    assert {:ok, turn} =
             Apps.submit_build_turn(scope, app.id, session.id, %{
               instructions: "Build searchable notes",
               operation_key: Ecto.UUID.generate()
             })

    assert turn.session_id == session.id
    assert Remote.calls() == []
  end

  test "apps and all derived resources deny cross-organization access", %{
    scope: scope,
    app: app,
    session: session
  } do
    other = app_scope_fixture()
    assert {:error, :not_found} = Apps.get_app(other, app.id)

    assert {:error, :execution_actor_ineligible} =
             Apps.start_build(other, app.id, %{operation_key: Ecto.UUID.generate()})

    assert {:error, :not_found} =
             Apps.submit_build_turn(other, app.id, session.id, %{
               instructions: "Cross org",
               operation_key: Ecto.UUID.generate()
             })

    assert {:error, :forbidden} =
             Apps.get_app(%{scope | membership: %{scope.membership | permissions: []}}, app.id)

    assert Remote.calls() == []
  end

  test "app creation retries reuse one app and environment and reject changed intent", %{
    scope: scope
  } do
    attrs = %{
      name: "Retryable notes",
      slug: "retryable-notes",
      repository: "owner/notes",
      operation_key: Ecto.UUID.generate()
    }

    assert {:ok, app} = Apps.create_app(scope, attrs)
    assert [environment] = Apps.list_environments(scope, app.id)
    assert {:ok, same} = Apps.create_app(scope, attrs)
    assert same.id == app.id
    assert Apps.list_environments(scope, app.id) == [environment]
    assert Enum.count(Apps.list_apps(scope), &(&1.slug == attrs.slug)) == 1
    assert Remote.calls() == []

    assert {:error, :operation_key_conflict} =
             Apps.create_app(scope, Map.put(attrs, :name, "A different intent"))

    assert {:error, :invalid_operation_key} =
             Apps.create_app(scope, Map.put(attrs, :operation_key, ""))
  end

  test "preview explicitly acquires a writer, verifies served revision and shares with expiry", %{
    scope: scope,
    app: app,
    session: session
  } do
    attrs = %{
      session_id: session.id,
      source_commit: String.duplicate("a", 40),
      operation_key: Ecto.UUID.generate()
    }

    assert {:ok, preview} = Apps.ensure_preview(scope, app.id, attrs)
    assert preview.status == "ready"
    assert preview.verification["served_revision"] == attrs.source_commit
    assert {:ok, lease} = Workspaces.get_lease(scope, preview.lease_id)
    assert lease.status == :released
    calls = Remote.calls()
    assert {:ok, same} = Apps.ensure_preview(scope, app.id, attrs)
    assert same.id == preview.id
    assert Remote.calls() == calls

    assert {:ok, %{grant: grant, url: url}} =
             Apps.create_access_grant(scope, app.id, %{preview_id: preview.id, expires_in: 600})

    assert String.ends_with?(URI.parse(url).host, ".apps.example.test")
    ["gateway", token] = URI.parse(url).path |> String.split("/", trim: true)
    assert {:ok, %{workspace_id: workspace_id}} = Apps.resolve_access(token)
    assert workspace_id == session.workspace_id
    assert {:ok, _grant} = Apps.revoke_access_grant(scope, grant.id)
    assert {:error, :access_revoked} = Apps.resolve_access(token)

    assert {:error, :invalid_access_expiry} =
             Apps.create_access_grant(scope, app.id, %{preview_id: preview.id, expires_in: 0})

    assert Apps.list_previews(scope, app.id) == [preview]
    assert Remote.calls() == calls
  end

  test "review binds source artifact, configuration and expected prior release", %{
    scope: scope,
    app: app,
    session: session
  } do
    attrs = deployment_attrs_fixture(scope, app, session)
    review = approve_deployment_fixture(scope, app, attrs)

    assert {:error, :review_mismatch_or_not_approved} =
             Apps.request_deployment(
               scope,
               app.id,
               attrs
               |> Map.put(:review_id, review.id)
               |> Map.put(:source_commit, String.duplicate("b", 40))
             )

    assert {:error, :artifact_digest_mismatch} =
             Apps.request_deployment(
               scope,
               app.id,
               attrs
               |> Map.put(:review_id, review.id)
               |> Map.put(:artifact_digest, String.duplicate("0", 64))
             )

    assert {:error, :configuration_changed} =
             Apps.request_deployment(
               scope,
               app.id,
               attrs
               |> Map.put(:review_id, review.id)
               |> Map.put(:configuration_digest, "changed")
             )

    assert {:ok, deployment} =
             Apps.request_deployment(scope, app.id, Map.put(attrs, :review_id, review.id))

    assert deployment.status == "queued"
    assert_enqueued(worker: ReleaseWorker, args: %{deployment_id: deployment.id})

    assert {:ok, same} =
             Apps.request_deployment(scope, app.id, Map.put(attrs, :review_id, review.id))

    assert same.id == deployment.id
    assert {:ok, deployment} = Apps.reconcile_deployment(deployment.id)
    assert deployment.status == "active"
    assert deployment.verification["served_revision"] == attrs.source_commit
    assert {:ok, artifact} = Artifacts.get(scope, deployment.artifact_id)
    assert artifact.digest == attrs.artifact_digest
  end

  test "competing releases cannot replace an unexpected active deployment", %{
    scope: scope,
    app: app,
    session: session
  } do
    first = deployment_attrs_fixture(scope, app, session)
    second = deployment_attrs_fixture(scope, app, session, String.duplicate("b", 40))
    first_review = approve_deployment_fixture(scope, app, first)
    second_review = approve_deployment_fixture(scope, app, second)

    {:ok, first_record} =
      Apps.request_deployment(scope, app.id, Map.put(first, :review_id, first_review.id))

    {:ok, second_record} =
      Apps.request_deployment(scope, app.id, Map.put(second, :review_id, second_review.id))

    assert {:ok, promoted} = Apps.reconcile_deployment(first_record.id)
    calls = Remote.calls()
    assert {:error, :active_deployment_changed} = Apps.reconcile_deployment(second_record.id)
    assert Remote.calls() == calls
    assert {:ok, environment} = Apps.get_environment(scope, promoted.environment_id)
    assert environment.active_deployment_id == promoted.id
  end

  test "upgrading uses the same persistent environment and independently exported data", %{
    scope: scope,
    app: app,
    session: session
  } do
    first = deployment_fixture(scope, app, session)
    {:ok, environment} = Apps.get_environment(scope, first.environment_id)
    assert environment.workspace_id != session.workspace_id
    Remote.add_write(environment.workspace_id, "Customer note")
    second = deployment_fixture(scope, app, session, String.duplicate("b", 40))
    assert Remote.data(environment.workspace_id) == ["Customer note"]
    assert {:ok, current} = Apps.get_environment(scope, environment.id)
    assert current.workspace_id == environment.workspace_id
    assert current.active_deployment_id == second.id
    assert {:ok, backup} = Apps.get_backup(scope, second.backup_id)
    assert backup.verification["restoration"] == "verified"
    assert {:ok, backup_content} = Artifacts.read(scope, backup.artifact_id)
    assert Jason.decode!(backup_content)["notes"] == ["Customer note"]
    assert {:ok, old} = Apps.get_deployment(scope, first.id)
    assert old.status == "superseded"
  end

  test "a lost activation-marker response reconciles the existing release once", %{
    scope: scope,
    app: app,
    session: session
  } do
    attrs = deployment_attrs_fixture(scope, app, session)
    review = approve_deployment_fixture(scope, app, attrs)

    {:ok, admitted} =
      Apps.request_deployment(scope, app.id, Map.put(attrs, :review_id, review.id))

    Remote.lose_marker_response()
    assert {:ok, deployment} = Apps.reconcile_deployment(admitted.id)
    assert deployment.status == "active"

    assert Enum.count(Remote.calls(), fn
             {:ensure_service, _workspace, "hs-app", _spec} -> true
             _call -> false
           end) == 1

    calls = Remote.calls()
    assert {:ok, _same} = Apps.reconcile_deployment(admitted.id)
    assert Remote.calls() == calls
  end

  test "failed activation restores compatible old code while retaining customer writes", %{
    scope: scope,
    app: app,
    session: session
  } do
    first = deployment_fixture(scope, app, session)
    {:ok, environment} = Apps.get_environment(scope, first.environment_id)
    Remote.add_write(environment.workspace_id, "Created after first publication")
    attrs = deployment_attrs_fixture(scope, app, session, String.duplicate("b", 40))
    review = approve_deployment_fixture(scope, app, attrs)
    {:ok, failed} = Apps.request_deployment(scope, app.id, Map.put(attrs, :review_id, review.id))
    Remote.fail_activation()
    assert {:error, :service_failed} = Apps.reconcile_deployment(failed.id)
    assert {:ok, failed} = Apps.get_deployment(scope, failed.id)
    assert failed.status == "failed"
    assert {:ok, current} = Apps.get_environment(scope, environment.id)
    assert current.active_deployment_id == first.id
    assert current.status == "running"
    assert Remote.data(environment.workspace_id) == ["Created after first publication"]
  end

  test "code rollback and data recovery require distinct exact approvals", %{
    scope: scope,
    app: app,
    session: session
  } do
    first = deployment_fixture(scope, app, session)
    {:ok, environment} = Apps.get_environment(scope, first.environment_id)
    Remote.add_write(environment.workspace_id, "Before upgrade")
    second = deployment_fixture(scope, app, session, String.duplicate("b", 40))
    Remote.add_write(environment.workspace_id, "After upgrade")

    rollback_attrs = %{
      environment_id: first.environment_id,
      session_id: first.session_id,
      source_commit: first.source_commit,
      artifact_id: first.artifact_id,
      artifact_digest: first.artifact_digest,
      configuration_digest: environment.configuration_digest,
      expected_active_deployment: second.id,
      rollback_of_id: first.id,
      operation_key: Ecto.UUID.generate()
    }

    review = approve_deployment_fixture(scope, app, rollback_attrs)

    assert {:ok, rollback} =
             Apps.request_rollback(
               scope,
               first.id,
               Map.put(rollback_attrs, :review_id, review.id)
             )

    assert {:ok, %{status: "active"}} = Apps.reconcile_deployment(rollback.id)
    assert Remote.data(environment.workspace_id) == ["Before upgrade", "After upgrade"]

    assert {:error, :review_mismatch_or_not_approved} =
             Apps.restore_data(scope, environment.id, second.backup_id, %{
               review_id: review.id,
               operation_key: Ecto.UUID.generate()
             })

    assert {:ok, target} = Apps.restore_target_digest(scope, environment.id, second.backup_id)
    data_review = approve_fixture(scope, "apps.restore_data", target)
    recovery_attrs = %{review_id: data_review.id, operation_key: Ecto.UUID.generate()}

    assert {:ok, recovery} =
             Apps.restore_data(scope, environment.id, second.backup_id, recovery_attrs)

    assert_enqueued(worker: RecoveryWorker, args: %{recovery_id: recovery.id})

    assert {:ok, same} =
             Apps.restore_data(scope, environment.id, second.backup_id, recovery_attrs)

    assert recovery.id == same.id
    assert {:ok, restored} = Apps.reconcile_recovery(recovery.id)
    assert restored.status == "restored"
    assert Remote.data(environment.workspace_id) == ["Before upgrade"]
    Remote.add_write(environment.workspace_id, "After recovery")
    assert {:ok, _same} = Apps.reconcile_recovery(recovery.id)
    assert Remote.data(environment.workspace_id) == ["Before upgrade", "After recovery"]

    assert {:error, :review_already_used} =
             Apps.restore_data(scope, environment.id, second.backup_id, %{
               review_id: data_review.id,
               operation_key: Ecto.UUID.generate()
             })
  end

  test "historical app reads and redacted logs issue no remote work", %{
    scope: scope,
    app: app,
    session: session
  } do
    deployed = deployment_fixture(scope, app, session)

    assert {:ok, log} =
             Apps.record_log(
               scope,
               app,
               deployed.environment_id,
               deployed.id,
               "diagnostic",
               "Authorization: Bearer secret-value123 token=secret-value456 sk-private12345678"
             )

    refute log.content =~ "secret-value"
    refute log.content =~ "sk-private"
    calls = Remote.calls()
    assert {:ok, _app} = Apps.get_app(scope, app.id)
    assert {:ok, _deployment} = Apps.get_deployment(scope, deployed.id)
    assert is_list(Apps.list_deployments(scope, app.id))
    assert is_list(Apps.read_logs(scope, app.id))
    assert Remote.calls() == calls
  end

  test "published public access is an explicit review bound to the verified active release", %{
    scope: scope,
    app: app,
    session: session
  } do
    deployment = deployment_fixture(scope, app, session)
    assert {:error, :private_environment} = Apps.public_url(scope, deployment.environment_id)
    {:ok, target} = Apps.publication_target_digest(scope, deployment.environment_id, true)
    review = approve_fixture(scope, "apps.publish", target)

    assert {:ok, environment} =
             Apps.publish_environment(scope, deployment.environment_id, %{
               review_id: review.id,
               public: true
             })

    assert environment.public
    assert {:ok, url} = Apps.public_url(scope, environment.id)
    assert URI.parse(url).host == environment.id <> ".apps.example.test"
    assert URI.parse(url).scheme == "https"

    Application.put_env(:hermitscale, Apps,
      gateway_host: "apps.example.test",
      gateway_scheme: "http"
    )

    assert {:ok, local_url} = Apps.public_url(scope, environment.id)
    assert URI.parse(local_url).scheme == "http"
    assert {:ok, %{workspace_id: workspace_id}} = Apps.resolve_access("public-" <> environment.id)
    assert workspace_id == environment.workspace_id

    assert {:error, :review_mismatch_or_not_approved} =
             Apps.publish_environment(scope, environment.id, %{
               review_id: review.id,
               public: false
             })
  end

  test "backup policy schedules durable exports and duplicate operation keys reuse one backup", %{
    scope: scope,
    app: app,
    session: session
  } do
    deployment = deployment_fixture(scope, app, session)
    {:ok, environment} = Apps.get_environment(scope, deployment.environment_id)
    Remote.add_write(environment.workspace_id, "A customer write")
    operation_key = Ecto.UUID.generate()
    assert {:ok, backup} = Apps.backup_environment(scope, environment.id, operation_key)
    calls = Remote.calls()
    assert {:ok, same} = Apps.backup_environment(scope, environment.id, operation_key)
    assert same.id == backup.id
    assert Remote.calls() == calls
    assert {:ok, :scheduled} = Apps.schedule_due_backups()
    refute_enqueued(worker: Hermitscale.Apps.BackupWorker)
    old = DateTime.add(DateTime.utc_now(), -90_000, :second)

    Repo.update_all(
      from(b in Hermitscale.Apps.Backup, where: b.environment_id == ^environment.id),
      set: [inserted_at: old]
    )

    assert {:ok, :scheduled} = Apps.schedule_due_backups()

    assert_enqueued(
      worker: Hermitscale.Apps.BackupWorker,
      args: %{environment_id: environment.id}
    )
  end

  test "defect verification binds a live response digest to the active served release", %{
    scope: scope,
    app: app,
    session: session
  } do
    deployment = deployment_fixture(scope, app, session)
    health = Jason.encode!(%{"revision" => deployment.source_commit, "database" => "ok"})
    expected = :crypto.hash(:sha256, health) |> Base.encode16(case: :lower)
    operation_key = Ecto.UUID.generate()

    assert {:ok, artifact} =
             Apps.verify_defect(scope, app.id, deployment.environment_id, %{
               path: "/__hermitscale/health",
               expected_status: 200,
               expected_body_digest: expected,
               operation_key: operation_key
             })

    assert artifact.kind == "defect_verification"
    assert artifact.owner_type == "deployment"
    assert artifact.owner_id == deployment.id
    assert {:ok, content} = Artifacts.read(scope, artifact.id)
    proof = Jason.decode!(content)
    assert proof["verified"]
    assert proof["source_commit"] == deployment.source_commit
    assert proof["body_digest"] == expected
    calls = Remote.calls()

    assert {:ok, same} =
             Apps.verify_defect(scope, app.id, deployment.environment_id, %{
               path: "/__hermitscale/health",
               expected_status: 200,
               expected_body_digest: expected,
               operation_key: operation_key
             })

    assert same.id == artifact.id
    assert Remote.calls() == calls

    assert {:error, :defect_check_failed} =
             Apps.verify_defect(scope, app.id, deployment.environment_id, %{
               path: "/__hermitscale/health",
               expected_body_digest: String.duplicate("0", 64)
             })

    assert {:error, :invalid_verification_path} =
             Apps.verify_defect(scope, app.id, deployment.environment_id, %{
               path: "https://other.example.test",
               expected_body_digest: expected
             })

    assert {:error, :execution_actor_ineligible} =
             Apps.verify_defect(app_scope_fixture(), app.id, deployment.environment_id, %{
               path: "/",
               expected_body_digest: expected
             })
  end

  test "support source selection verifies serving identity and app ownership without waking compute",
       %{
         scope: scope,
         app: app,
         session: session
       } do
    deployment = deployment_fixture(scope, app, session)
    calls = Remote.calls()

    assert {:ok, source} = Apps.investigation_source(scope, app.id, deployment.environment_id)
    assert source.deployment.id == deployment.id

    assert source.source_bundle == %{
             "app_id" => app.id,
             "artifact_id" => deployment.artifact_id,
             "artifact_digest" => deployment.artifact_digest,
             "deployed_revision" => deployment.source_commit
           }

    assert {:error, :not_found} =
             Apps.investigation_source(app_scope_fixture(), app.id, deployment.environment_id)

    other_app = app_fixture(scope)
    [other_environment] = Apps.list_environments(scope, other_app.id)

    assert {:error, :serving_source_not_verified} =
             Apps.investigation_source(scope, app.id, other_environment.id)

    assert {:ok, foreign_source} =
             Artifacts.record(scope, %{
               owner_type: "app",
               owner_id: other_app.id,
               kind: "source_bundle",
               content_type: "application/x-tar",
               content: "another app's code"
             })

    deployment
    |> Ecto.Changeset.change(
      artifact_id: foreign_source.id,
      artifact_digest: foreign_source.digest
    )
    |> Hermitscale.Repo.update!()

    assert {:error, :serving_source_not_verified} =
             Apps.investigation_source(scope, app.id, deployment.environment_id)

    assert Remote.calls() == calls
  end

  defp restore(key, nil), do: Application.delete_env(:hermitscale, key)
  defp restore(key, value), do: Application.put_env(:hermitscale, key, value)
end
