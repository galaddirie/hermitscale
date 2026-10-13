defmodule Hermitscale.Apps do
  @moduledoc """
  Organization-owned apps, explicit previews, independently hosted releases and SQLite recovery.

  Inspection uses committed metadata. Remote activity is admitted through Workspaces,
  and promotions compare the exact expected prior deployment. App code, build data
  and published customer data have independent lifetimes.
  """
  import Ecto.Query
  alias Ecto.Changeset
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.{Agents, Artifacts, Authorization, Repo, Reviews, Workspaces}

  alias Hermitscale.Apps.{
    AccessGrant,
    App,
    Backup,
    BuildSession,
    DataRecovery,
    Deployment,
    Environment,
    Log,
    Preview,
    RecoveryWorker,
    ReleaseWorker
  }

  @recipe "python-sqlite-v1"

  def list_apps(scope) do
    with :ok <- Authorization.authorize(scope, "apps:read") do
      Repo.all(
        from a in App,
          where: a.org_id == ^Scope.organization_id!(scope),
          order_by: [desc: a.updated_at],
          limit: 100
      )
    end
  end

  def get_app(scope, id), do: fetch(scope, App, id, "apps:read")
  def get_environment(scope, id), do: fetch(scope, Environment, id, "apps:read")
  def get_preview(scope, id), do: fetch(scope, Preview, id, "apps:read")
  def get_deployment(scope, id), do: fetch(scope, Deployment, id, "apps:read")
  def get_backup(scope, id), do: fetch(scope, Backup, id, "apps:read")

  @doc "Selects the immutable, verified serving source for an authorized support investigation."
  def investigation_source(scope, app_id, environment_id) do
    with {:ok, app} <- get_app(scope, app_id),
         {:ok, environment} <- get_environment(scope, environment_id),
         true <- environment.app_id == app.id and environment.status == "running",
         {:ok, deployment} <- get_deployment(scope, environment.active_deployment_id),
         true <-
           deployment.app_id == app.id and deployment.environment_id == environment.id and
             deployment.status == "active" and
             deployment.verification["served_revision"] == deployment.source_commit,
         {:ok, artifact} <- Artifacts.get(scope, deployment.artifact_id),
         true <-
           artifact.owner_type == "app" and artifact.owner_id == app.id and
             artifact.kind == "source_bundle" and artifact.digest == deployment.artifact_digest and
             digest_bytes(artifact.content) == deployment.artifact_digest do
      {:ok,
       %{
         app: app,
         environment: environment,
         deployment: deployment,
         source_bundle: %{
           "app_id" => app.id,
           "artifact_id" => artifact.id,
           "artifact_digest" => artifact.digest,
           "deployed_revision" => deployment.source_commit
         }
       }}
    else
      false -> {:error, :serving_source_not_verified}
      {:error, _reason} = error -> error
    end
  end

  def change_app(scope, attrs \\ %{}) do
    %App{org_id: Scope.organization_id!(scope), created_by_user_id: scope.user.id}
    |> App.changeset(attrs)
  end

  def create_app(scope, attrs) when is_map(attrs) do
    with {:ok, scope} <- execution_scope(scope, "apps:write"),
         {:ok, operation_key} <- app_operation_key(attrs) do
      changeset = change_app(scope, attrs)

      case {operation_key, changeset.valid?} do
        {_key, false} -> {:error, changeset}
        {nil, true} -> Repo.transaction(fn -> insert_app!(scope, changeset) end)
        {key, true} -> keyed_create_app(scope, changeset, key)
      end
    end
  end

  defp app_operation_key(attrs) do
    case {Map.has_key?(attrs, :operation_key) or Map.has_key?(attrs, "operation_key"),
          value(attrs, :operation_key)} do
      {false, nil} -> {:ok, nil}
      {true, key} when is_binary(key) and byte_size(key) in 8..128 -> {:ok, key}
      {true, _invalid} -> {:error, :invalid_operation_key}
    end
  end

  defp keyed_create_app(scope, changeset, key) do
    org = Scope.organization_id!(scope)
    actor = scope.user.id
    identity = :crypto.hash(:sha256, :erlang.term_to_binary({org, actor, key}, [:deterministic]))
    {:ok, id} = Ecto.UUID.load(binary_part(identity, 0, 16))
    lock = rem(:binary.decode_unsigned(binary_part(identity, 0, 8)), 9_223_372_036_854_775_807)
    fields = [:name, :slug, :repository, :recipe]
    intent = changeset |> Changeset.apply_changes() |> Map.take(fields)

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock])

      case Repo.get(App, id) do
        %App{org_id: ^org, created_by_user_id: ^actor} = app ->
          if Map.take(app, fields) == intent,
            do: app,
            else: Repo.rollback(:operation_key_conflict)

        nil ->
          insert_app!(scope, Changeset.put_change(changeset, :id, id))

        %App{} ->
          Repo.rollback(:operation_key_conflict)
      end
    end)
  end

  defp insert_app!(scope, changeset) do
    app = unwrap!(Repo.insert(changeset))
    _environment = unwrap!(create_environment(scope, app.id, %{name: "production"}))
    app
  end

  def create_environment(scope, app_id, attrs) when is_map(attrs) do
    with :ok <- Authorization.authorize(scope, "apps:write"),
         {:ok, app} <- get_app(scope, app_id),
         {:ok, configuration} <- validate_configuration(value(attrs, :configuration, %{})) do
      Repo.transaction(fn ->
        id = Ecto.UUID.generate()
        name = value(attrs, :name, "production")

        workspace =
          unwrap!(
            Workspaces.ensure_workspace(scope, "app-environment:" <> id, %{recipe: @recipe})
          )

        environment = %Environment{
          id: id,
          org_id: app.org_id,
          app_id: app.id,
          workspace_id: workspace.id
        }

        result =
          unwrap!(
            Repo.insert(
              Environment.changeset(environment, %{
                name: name,
                configuration: configuration,
                configuration_digest: digest(configuration)
              })
            )
          )

        _protection =
          unwrap!(
            Workspaces.protect_workspace(
              scope,
              workspace.id,
              "app:" <> app.id,
              "Published app data"
            )
          )

        result
      end)
    end
  end

  def update_environment(scope, id, attrs) do
    with {:ok, scope} <- execution_scope(scope, "apps:write"),
         {:ok, environment} <- get_environment(scope, id),
         {:ok, configuration} <- validate_configuration(value(attrs, :configuration, %{})) do
      Repo.transaction(fn ->
        current = lock!(Environment, environment.id, environment.org_id)
        if current.release_operation_id, do: Repo.rollback(:release_in_progress)

        unwrap!(
          Repo.update(
            Environment.changeset(current, %{
              configuration: configuration,
              configuration_digest: digest(configuration)
            })
          )
        )
      end)
    end
  end

  def list_environments(scope, app_id), do: list_owned(scope, app_id, Environment)
  def list_deployments(scope, app_id), do: list_owned(scope, app_id, Deployment)
  def list_previews(scope, app_id), do: list_owned(scope, app_id, Preview)

  @doc "Inspects organization workflow definitions with literal bindings to this app or its environments."
  def list_workflows(scope, app_id) do
    with {:ok, app} <- get_app(scope, app_id) do
      environments = list_environments(scope, app.id) |> Enum.map(& &1.id)

      Hermitscale.Workflows.list_graphs(scope)
      |> Enum.filter(fn graph ->
        nodes =
          case graph.definition do
            %{"nodes" => nodes} when is_list(nodes) -> nodes
            _invalid_draft -> []
          end

        Enum.any?(nodes, fn
          %{"type" => type, "params" => params} when is_binary(type) and is_map(params) ->
            String.starts_with?(type, "apps.") and
              (Map.get(params, "app_id") == app.id or
                 Map.get(params, "environment_id") in environments)

          _invalid_draft_node ->
            false
        end)
      end)
    end
  end

  def list_backups(scope, environment_id) do
    with {:ok, environment} <- get_environment(scope, environment_id) do
      Repo.all(
        from b in Backup,
          where: b.environment_id == ^environment.id and b.org_id == ^environment.org_id,
          order_by: [desc: b.inserted_at],
          limit: 100
      )
    end
  end

  @doc "Explicitly wakes the current release for a bounded, read-only defect acceptance check."
  def verify_defect(scope, app_id, environment_id, attrs) do
    with {:ok, scope} <- execution_scope(scope, "apps:deploy"),
         {:ok, app} <- get_app(scope, app_id),
         {:ok, environment} <- get_environment(scope, environment_id),
         true <- environment.app_id == app.id and environment.status == "running",
         {:ok, deployment} <- get_deployment(scope, environment.active_deployment_id),
         true <-
           deployment.status == "active" and
             deployment.verification["served_revision"] == deployment.source_commit,
         {:ok, path, status, expected} <- defect_check(attrs),
         {:ok, operation_key} <- uuid(value(attrs, :operation_key, Ecto.UUID.generate())),
         {:ok, lease} <-
           admit_activity(
             scope,
             environment.workspace_id,
             "defect:" <> operation_key,
             DateTime.add(DateTime.utc_now(), 120, :second)
           ) do
      proof = defect_proof(environment, deployment, lease, path, status, expected)

      case Artifacts.find(scope, %{
             owner_type: "deployment",
             owner_id: deployment.id,
             kind: "defect_verification",
             digest: digest_bytes(Jason.encode!(proof))
           }) do
        {:ok, artifact} ->
          with :ok <- finish_defect_activity(scope, environment, lease), do: {:ok, artifact}

        {:error, :not_found} ->
          with {:ok, _lease} <- Workspaces.validate_lease(scope, lease.id) do
            result = verify_defect_under_lease(scope, environment, deployment, proof)

            case {result, release_activity(scope, environment.workspace_id, lease.id)} do
              {{:ok, artifact}, :ok} -> {:ok, artifact}
              {{:error, _reason} = error, _cleanup} -> error
              {{:ok, _artifact}, {:error, _reason} = error} -> error
            end
          end

        {:error, _reason} = error ->
          error
      end
    else
      false -> {:error, :deployment_not_verified}
      {:error, _reason} = error -> error
    end
  end

  defp defect_proof(environment, deployment, lease, path, status, expected) do
    %{
      "app_id" => environment.app_id,
      "environment_id" => environment.id,
      "deployment_id" => deployment.id,
      "source_commit" => deployment.source_commit,
      "served_revision" => deployment.source_commit,
      "health" => "passed",
      "check_started_at" => DateTime.to_iso8601(lease.inserted_at),
      "lease_id" => lease.id,
      "path" => path,
      "status" => status,
      "body_digest" => expected,
      "verified" => true
    }
  end

  defp finish_defect_activity(_scope, _environment, %{status: :released}), do: :ok

  defp finish_defect_activity(scope, environment, lease),
    do: release_activity(scope, environment.workspace_id, lease.id)

  defp verify_defect_under_lease(scope, environment, deployment, proof) do
    with {:ok, served} <-
           verify_served(scope, environment.workspace_id, deployment.source_commit),
         {:ok, response} <-
           Workspaces.app_request(scope, environment.workspace_id, proof["path"], method: :get),
         {:ok, body} <- defect_body(response.body),
         true <-
           served["served_revision"] == proof["served_revision"] and
             response.status == proof["status"] and digest_bytes(body) == proof["body_digest"] do
      Repo.transaction(fn ->
        current = lock!(Environment, environment.id, environment.org_id)
        compare_active!(current, deployment.id)
        if current.release_operation_id, do: Repo.rollback(:release_in_progress)

        unwrap!(
          Artifacts.record(scope, %{
            owner_type: "deployment",
            owner_id: deployment.id,
            kind: "defect_verification",
            content_type: "application/json",
            content: Jason.encode!(proof)
          })
        )
      end)
    else
      false -> {:error, :defect_check_failed}
      {:error, _reason} = error -> error
    end
  end

  defp defect_check(attrs) do
    path = value(attrs, :path)
    status = value(attrs, :expected_status, 200)
    expected = value(attrs, :expected_body_digest)

    cond do
      not is_binary(path) or byte_size(path) > 2048 ->
        {:error, :invalid_verification_path}

      not String.starts_with?(path, "/") or String.starts_with?(path, "//") or
          String.contains?(path, [<<0>>, "\\", ".."]) ->
        {:error, :invalid_verification_path}

      not is_integer(status) or status not in 100..599 ->
        {:error, :invalid_expected_status}

      not is_binary(expected) ->
        {:error, :invalid_expected_body_digest}

      not Regex.match?(~r/\A[0-9a-f]{64}\z/, expected) ->
        {:error, :invalid_expected_body_digest}

      true ->
        {:ok, path, status, expected}
    end
  end

  defp defect_body(body) when is_binary(body) and byte_size(body) <= 65_536, do: {:ok, body}
  defp defect_body(body) when is_map(body) or is_list(body), do: defect_body(Jason.encode!(body))
  defp defect_body(_body), do: {:error, :verification_response_too_large}

  def list_build_sessions(scope, app_id) do
    with {:ok, app} <- get_app(scope, app_id) do
      Repo.all(
        from b in BuildSession,
          where: b.app_id == ^app.id and b.org_id == ^app.org_id,
          order_by: [desc: b.inserted_at],
          limit: 100
      )
      |> Enum.filter(fn build ->
        match?({:ok, _session}, Agents.get_session(scope, build.session_id))
      end)
    end
  end

  def start_build(scope, app_id, attrs) when is_map(attrs) do
    with {:ok, scope} <- execution_scope(scope, "apps:write"),
         {:ok, app} <- get_app(scope, app_id),
         {:ok, operation_key} <- key(value(attrs, :operation_key)) do
      Repo.transaction(fn ->
        _app = lock!(App, app.id, app.org_id)

        case Repo.get_by(BuildSession, app_id: app.id, operation_key: operation_key) do
          %BuildSession{} = build ->
            unwrap!(Agents.get_session(scope, build.session_id))

          nil ->
            session =
              unwrap!(
                Agents.start_session(scope, %{
                  title: app.name <> " · build",
                  repository: app.repository,
                  base_sha: value(attrs, :base_sha),
                  connection_set: value(attrs, :connection_set, %{}),
                  recipe: @recipe
                })
              )

            %BuildSession{org_id: app.org_id, app_id: app.id, session_id: session.id}
            |> BuildSession.changeset(%{operation_key: operation_key})
            |> Repo.insert()
            |> unwrap!()

            session
        end
      end)
    end
  end

  @doc "Links a private, source-bound support investigation to its app for follow-up build work."
  def attach_investigation(scope, app_id, session_id, operation_key) do
    with {:ok, scope} <- execution_scope(scope, "support:investigate"),
         {:ok, app} <- get_app(scope, app_id),
         {:ok, session} <- Agents.get_session(scope, session_id),
         true <-
           session.initiator_user_id == scope.user.id and
             session.source_bundle["app_id"] == app.id,
         {:ok, operation_key} <- key(operation_key) do
      Repo.transaction(fn ->
        _app = lock!(App, app.id, app.org_id)

        case Repo.get_by(BuildSession, app_id: app.id, operation_key: operation_key) do
          %BuildSession{session_id: id} = build when id == session.id ->
            build

          %BuildSession{} ->
            Repo.rollback(:operation_key_conflict)

          nil ->
            %BuildSession{org_id: app.org_id, app_id: app.id, session_id: session.id}
            |> BuildSession.changeset(%{operation_key: operation_key})
            |> Repo.insert()
            |> unwrap!()
        end
      end)
    else
      false -> {:error, :investigation_source_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def submit_build_turn(scope, app_id, session_id, attrs) do
    with :ok <- Authorization.authorize(scope, "apps:write"),
         {:ok, _app, session} <- build_session(scope, app_id, session_id) do
      Agents.submit_turn(scope, session.id, attrs)
    end
  end

  @doc "Explicitly wakes and verifies an editing preview; inspecting its record does not wake it."
  def ensure_preview(scope, app_id, attrs) when is_map(attrs) do
    with {:ok, scope} <- execution_scope(scope, "apps:write"),
         {:ok, app, session} <-
           build_session(
             scope,
             app_id,
             value(attrs, :session_id, value(attrs, :source_session_id))
           ),
         {:ok, source_commit} <-
           revision(value(attrs, :source_commit, value(attrs, :source_revision))),
         {:ok, operation_key} <- key(value(attrs, :operation_key)),
         {:ok, preview} <- admit_preview(app, session, source_commit, operation_key) do
      case preview.status do
        "ready" -> {:ok, preview}
        "starting" -> start_preview(scope, preview)
        "failed" -> {:error, :preview_failed}
      end
    end
  end

  defp admit_preview(app, session, source_commit, operation_key) do
    Repo.transaction(fn ->
      _app = lock!(App, app.id, app.org_id)

      case Repo.get_by(Preview, app_id: app.id, operation_key: operation_key) do
        %Preview{session_id: session_id} = preview when session_id == session.id ->
          if preview.source_commit == source_commit or
               preview.verification["requested_source_commit"] == source_commit,
             do: preview,
             else: Repo.rollback(:operation_key_conflict)

        %Preview{} ->
          Repo.rollback(:operation_key_conflict)

        nil ->
          %Preview{
            org_id: app.org_id,
            app_id: app.id,
            session_id: session.id,
            workspace_id: session.workspace_id
          }
          |> Preview.changeset(%{
            source_commit: source_commit,
            operation_key: operation_key,
            expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
          })
          |> Repo.insert()
          |> unwrap!()
      end
    end)
  end

  defp start_preview(scope, preview) do
    with {:ok, _workspace} <- Workspaces.provision_workspace(scope, preview.workspace_id),
         {:ok, lease} <-
           Workspaces.admit_lease(
             scope,
             preview.workspace_id,
             "preview:" <> preview.id,
             preview.expires_at
           ),
         {:ok, preview} <- Repo.update(Changeset.change(preview, lease_id: lease.id)),
         :ok <- install_helper(scope, preview.workspace_id, lease.id),
         {:ok, frozen} <-
           command(
             scope,
             preview.workspace_id,
             lease.id,
             "freeze",
             preview.id,
             preview.source_commit
           ),
         {:ok, built} <-
           command(scope, preview.workspace_id, lease.id, "build", preview.id, frozen["revision"]),
         {:ok, _staged} <-
           command(
             scope,
             preview.workspace_id,
             lease.id,
             "preview",
             preview.id,
             frozen["revision"],
             built["digest"]
           ),
         {:ok, _service} <-
           Workspaces.ensure_service(
             scope,
             preview.workspace_id,
             lease.id,
             "hs-app",
             service(
               "preview-releases/" <> preview.id,
               "/workspace/preview-data",
               frozen["revision"]
             )
           ),
         {:ok, verification} <- verify_served(scope, preview.workspace_id, frozen["revision"]),
         :ok <- release_activity(scope, preview.workspace_id, lease.id),
         {:ok, preview} <-
           Repo.update(
             Changeset.change(preview,
               status: "ready",
               source_commit: frozen["revision"],
               verification:
                 Map.merge(verification, %{
                   "requested_source_commit" => preview.source_commit,
                   "change_manifest" => frozen["change_manifest"]
                 })
             )
           ) do
      broadcast(preview.app_id)

      Repo.update_all(
        from(p in Preview,
          where:
            p.workspace_id == ^preview.workspace_id and p.id != ^preview.id and
              p.status == "ready"
        ),
        set: [status: "superseded"]
      )

      {:ok, preview}
    else
      {:ok, %{exit_code: code, output: output}} ->
        _ =
          Repo.update(
            Changeset.change(preview,
              status: "failed",
              verification: %{"exit_code" => code, "output" => redact(output)}
            )
          )

        {:error, :preview_source_mismatch}

      {:error, reason} = error ->
        _ =
          Repo.update(
            Changeset.change(preview, verification: %{"error" => reason_string(reason)})
          )

        error
    end
  end

  @doc "Builds the frozen commit and persists a credential-free, checksummed code artifact."
  def build_artifact(scope, app_id, session_id, source_commit, operation_key, opts \\ []) do
    with {:ok, scope} <- execution_scope(scope, "apps:deploy"),
         {:ok, app, session} <- build_session(scope, app_id, session_id),
         {:ok, source_commit} <- revision(source_commit),
         {:ok, operation_key} <- uuid(operation_key),
         {:ok, _workspace} <- Workspaces.provision_workspace(scope, session.workspace_id),
         {:ok, lease} <-
           admit_activity(
             scope,
             session.workspace_id,
             "build:" <> operation_key,
             DateTime.add(DateTime.utc_now(), 600, :second)
           ),
         :ok <- install_helper(scope, session.workspace_id, lease.id),
         {:ok, frozen} <-
           freeze_for_build(
             scope,
             session.workspace_id,
             lease.id,
             operation_key,
             source_commit,
             Keyword.get(opts, :freeze, false)
           ),
         {:ok, result} <-
           command(
             scope,
             session.workspace_id,
             lease.id,
             "build",
             operation_key,
             frozen["revision"]
           ),
         {:ok, content} <-
           Workspaces.read_file(scope, session.workspace_id, lease.id, result["path"]),
         true <- digest_bytes(content) == result["digest"],
         {:ok, artifact} <-
           Artifacts.record(scope, %{
             owner_type: "app",
             owner_id: app.id,
             kind: "source_bundle",
             content_type: "application/x-tar",
             content: content
           }),
         :ok <- release_activity(scope, session.workspace_id, lease.id) do
      record_log(scope, app, nil, nil, "build", Jason.encode!(result))

      {:ok,
       %{
         artifact: artifact,
         source_commit: frozen["revision"],
         change_manifest: frozen["change_manifest"],
         checks: result["checks"]
       }}
    else
      false -> {:error, :artifact_digest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp freeze_for_build(scope, workspace_id, lease_id, operation_id, source_commit, true),
    do: command(scope, workspace_id, lease_id, "freeze", operation_id, source_commit)

  defp freeze_for_build(_scope, _workspace_id, _lease_id, _operation_id, source_commit, false),
    do: {:ok, %{"revision" => source_commit, "change_manifest" => []}}

  @doc "Exact approval identity, including source, immutable artifact, config and prior release."
  def deployment_target_digest(scope, app_id, attrs) do
    with {:ok, input} <- deployment_input(scope, app_id, attrs) do
      {:ok, input.target_digest}
    end
  end

  @doc "Records deployment intent and dispatch atomically; duplicate keys cannot change the release."
  def request_deployment(scope, app_id, attrs) when is_map(attrs) do
    with {:ok, scope} <- execution_scope(scope, "apps:deploy"),
         {:ok, input} <- deployment_input(scope, app_id, attrs),
         {:ok, review_id} <- uuid(value(attrs, :review_id)),
         :ok <-
           Reviews.authorize_decision(
             scope,
             review_id,
             "apps.deploy",
             input.target_digest,
             input.policy_revision
           ) do
      result =
        Repo.transaction(fn ->
          case Repo.get_by(Deployment, org_id: input.org_id, operation_key: input.operation_key) do
            %Deployment{input_digest: existing_digest} = existing
            when existing_digest == input.input_digest ->
              existing

            %Deployment{} ->
              Repo.rollback(:operation_key_conflict)

            nil ->
              environment = lock!(Environment, input.environment_id, input.org_id)
              compare_active!(environment, input.expected_active_deployment_id)

              deployment =
                %Deployment{
                  org_id: input.org_id,
                  app_id: input.app_id,
                  environment_id: input.environment_id,
                  session_id: input.session_id,
                  execution_actor_user_id: scope.user.id
                }
                |> Deployment.changeset(
                  Map.merge(input, %{
                    review_id: review_id,
                    deadline: DateTime.add(DateTime.utc_now(), 900, :second)
                  })
                )
                |> Repo.insert()
                |> unwrap!()

              unwrap!(Oban.insert(ReleaseWorker.new(%{deployment_id: deployment.id})))
              deployment
          end
        end)

      broadcast(input.app_id)
      result
    end
  end

  defp deployment_input(scope, app_id, attrs) do
    with {:ok, app} <- get_app(scope, app_id),
         {:ok, build} <-
           attached_build(app, value(attrs, :session_id, value(attrs, :source_session_id))),
         {:ok, environment} <- environment_for(scope, app, value(attrs, :environment_id)),
         {:ok, source_commit} <-
           revision(value(attrs, :source_commit, value(attrs, :source_revision))),
         {:ok, operation_key} <- key(value(attrs, :operation_key)),
         {:ok, artifact} <- Artifacts.get(scope, value(attrs, :artifact_id)),
         :ok <- source_artifact(app, artifact, value(attrs, :artifact_digest)),
         :ok <- configuration_match(environment, value(attrs, :configuration_digest)) do
      input = %{
        org_id: app.org_id,
        app_id: app.id,
        environment_id: environment.id,
        session_id: build.session_id,
        recipe: app.recipe,
        source_commit: source_commit,
        operation_key: operation_key,
        artifact_id: artifact.id,
        artifact_digest: artifact.digest,
        configuration_digest: environment.configuration_digest,
        expected_active_deployment_id:
          value(attrs, :expected_active_deployment, value(attrs, :expected_active_deployment_id)),
        policy_revision: value(attrs, :policy_revision, 1),
        rollback_of_id: value(attrs, :rollback_of_id)
      }

      target = input |> Map.drop([:operation_key]) |> digest()
      {:ok, input |> Map.put(:target_digest, target) |> Map.put(:input_digest, digest(input))}
    end
  end

  @doc false
  def reconcile_deployment(id) do
    with {:ok, id} <- uuid(id),
         %Deployment{} = deployment <- Repo.get(Deployment, id),
         {:ok, scope} <-
           execution_scope_for(
             deployment.org_id,
             deployment.execution_actor_user_id,
             "apps:deploy"
           ) do
      case deployment.status do
        status when status in ["active", "superseded", "rolled_back", "failed"] ->
          finish_recorded_release(scope, deployment)

        status when status in ["queued", "releasing", "verifying", "maintenance"] ->
          execute_release(scope, deployment)
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp finish_recorded_release(_scope, %{lease_id: nil} = deployment), do: {:ok, deployment}

  defp finish_recorded_release(scope, deployment) do
    with {:ok, lease} <- Workspaces.get_lease(scope, deployment.lease_id) do
      case lease.status do
        :released ->
          {:ok, deployment}

        :active ->
          with :ok <- release_activity(scope, lease.workspace_id, lease.id), do: {:ok, deployment}
      end
    end
  end

  defp execute_release(scope, deployment) do
    with :ok <-
           Reviews.authorize_decision(
             scope,
             deployment.review_id,
             "apps.deploy",
             deployment.target_digest,
             deployment.policy_revision
           ),
         {:ok, environment} <- claim_release(scope, deployment),
         {:ok, _workspace} <- Workspaces.provision_workspace(scope, environment.workspace_id),
         {:ok, lease} <- release_lease(scope, environment, deployment),
         :ok <- install_helper(scope, environment.workspace_id, lease.id) do
      current = Repo.get!(Deployment, deployment.id)
      reconcile_or_stage(scope, environment, current, lease)
    end
  end

  defp claim_release(scope, deployment) do
    Repo.transaction(fn ->
      environment = lock!(Environment, deployment.environment_id, Scope.organization_id!(scope))

      cond do
        environment.active_deployment_id == deployment.id ->
          environment

        environment.release_operation_id not in [nil, deployment.id] ->
          Repo.rollback(:release_in_progress)

        environment.configuration_digest != deployment.configuration_digest ->
          Repo.rollback(:configuration_changed)

        true ->
          compare_active!(environment, deployment.expected_active_deployment_id)

          unwrap!(
            Repo.update(
              Changeset.change(environment,
                release_operation_id: deployment.id,
                status: "maintenance"
              )
            )
          )
      end
    end)
  end

  defp release_lease(scope, environment, deployment) do
    with {:ok, lease} <-
           Workspaces.admit_lease(
             scope,
             environment.workspace_id,
             "release:" <> deployment.id,
             deployment.deadline
           ),
         {:ok, _deployment} <-
           Repo.update(Changeset.change(deployment, lease_id: lease.id, status: "releasing")) do
      {:ok, lease}
    end
  end

  defp reconcile_or_stage(scope, environment, deployment, lease) do
    case command(scope, environment.workspace_id, lease.id, "inspect", deployment.id) do
      {:ok,
       %{
         "operation_id" => operation_id,
         "revision" => revision,
         "artifact_digest" => artifact_digest
       }}
      when operation_id == deployment.id and revision == deployment.source_commit and
             artifact_digest == deployment.artifact_digest ->
        with {:ok, verification} <-
               verify_served(scope, environment.workspace_id, deployment.source_commit) do
          promote(scope, environment, deployment, lease, verification)
        end

      {:ok, %{"operation_id" => prior}}
      when prior == nil or prior == deployment.expected_active_deployment_id ->
        stage_release(scope, environment, deployment, lease)

      {:ok, %{"operation_id" => _other}} ->
        {:error, :remote_release_conflict}

      {:error, _reason} = error ->
        error
    end
  end

  defp stage_release(scope, environment, deployment, lease) do
    with {:ok, content} <- Artifacts.read(scope, deployment.artifact_id),
         true <- digest_bytes(content) == deployment.artifact_digest,
         :ok <-
           Workspaces.write_file(
             scope,
             environment.workspace_id,
             lease.id,
             "incoming/" <> deployment.id <> ".tar",
             content
           ),
         {:ok, _stopped} <-
           Workspaces.stop_service(scope, environment.workspace_id, lease.id, "hs-app"),
         {:ok, backup} <- backup_under_lease(scope, environment, deployment, lease),
         {:ok, staged} <-
           command(
             scope,
             environment.workspace_id,
             lease.id,
             "stage",
             deployment.id,
             deployment.source_commit,
             deployment.artifact_digest
           ),
         {:ok, _service} <-
           Workspaces.ensure_service(
             scope,
             environment.workspace_id,
             lease.id,
             "hs-app",
             service("releases/" <> deployment.id, "/workspace/data", deployment.source_commit)
           ),
         {:ok, verification} <-
           verify_served(scope, environment.workspace_id, deployment.source_commit),
         {:ok, _marker} <-
           command(
             scope,
             environment.workspace_id,
             lease.id,
             "mark",
             deployment.id,
             deployment.source_commit,
             deployment.artifact_digest,
             deployment.expected_active_deployment_id
           ) do
      verification = Map.merge(verification, %{"staged" => staged, "backup_id" => backup.id})
      promote(scope, environment, deployment, lease, verification)
    else
      false ->
        fail_release(scope, environment, deployment, lease, :artifact_digest_mismatch)

      {:error, reason} ->
        case verify_served(scope, environment.workspace_id, deployment.source_commit) do
          {:ok, verification} ->
            # A service switch or marker response may be lost after the remote effect.
            # Inspect its durable marker before repeating commands or rolling code back.
            case command(scope, environment.workspace_id, lease.id, "inspect", deployment.id) do
              {:ok, %{"operation_id" => id, "revision" => revision, "artifact_digest" => digest}}
              when id == deployment.id and revision == deployment.source_commit and
                     digest == deployment.artifact_digest ->
                promote(scope, environment, deployment, lease, verification)

              {:ok, %{"operation_id" => prior}}
              when prior == nil or prior == deployment.expected_active_deployment_id ->
                with {:ok, _marker} <-
                       command(
                         scope,
                         environment.workspace_id,
                         lease.id,
                         "mark",
                         deployment.id,
                         deployment.source_commit,
                         deployment.artifact_digest,
                         deployment.expected_active_deployment_id
                       ),
                     do: promote(scope, environment, deployment, lease, verification)

              {:ok, _other} ->
                {:error, :remote_release_conflict}

              {:error, _reason} ->
                {:error, :activation_uncertain}
            end

          {:error, :served_revision_mismatch} ->
            fail_release(scope, environment, deployment, lease, reason)

          {:error, _remote_reason} ->
            {:error, :activation_uncertain}
        end
    end
  end

  defp promote(scope, environment, deployment, lease, verification) do
    result =
      Repo.transaction(fn ->
        current = lock!(Environment, environment.id, environment.org_id)

        case current.active_deployment_id do
          id when id == deployment.id ->
            Repo.get!(Deployment, deployment.id)

          _id ->
            compare_active!(current, deployment.expected_active_deployment_id)

            if current.release_operation_id != deployment.id,
              do: Repo.rollback(:release_in_progress)

            if current.active_deployment_id do
              prior = Repo.get!(Deployment, current.active_deployment_id)
              unwrap!(Repo.update(Changeset.change(prior, status: "superseded")))
            end

            unwrap!(
              Repo.update(
                Changeset.change(current,
                  active_deployment_id: deployment.id,
                  release_operation_id: nil,
                  status: "running"
                )
              )
            )

            unwrap!(
              Repo.update(
                Changeset.change(Repo.get!(Deployment, deployment.id),
                  status: "active",
                  verification: verification
                )
              )
            )
        end
      end)

    with {:ok, deployed} <- result,
         :ok <- release_activity(scope, environment.workspace_id, lease.id) do
      record_log(
        scope,
        %{id: environment.app_id, org_id: environment.org_id},
        environment.id,
        deployment.id,
        "deployment",
        Jason.encode!(verification)
      )

      broadcast(environment.app_id)
      {:ok, deployed}
    end
  end

  defp fail_release(scope, environment, deployment, lease, reason) do
    # A failed code switch may be rolled back only after the old code accepts current data.
    rollback = rollback_service(scope, environment, deployment, lease)

    status =
      case rollback do
        :ok -> "failed"
        {:error, _reason} -> "maintenance"
      end

    _ =
      Repo.update(
        Changeset.change(Repo.get!(Deployment, deployment.id),
          status: status,
          error: %{"reason" => reason_string(reason)}
        )
      )

    case rollback do
      :ok ->
        _ =
          Repo.update(
            Changeset.change(Repo.get!(Environment, environment.id),
              release_operation_id: nil,
              status: if(environment.active_deployment_id, do: "running", else: "sleeping")
            )
          )

        _ = release_activity(scope, environment.workspace_id, lease.id)

      {:error, _reason} ->
        :ok
    end

    broadcast(environment.app_id)
    {:error, reason}
  end

  defp rollback_service(_scope, %{active_deployment_id: nil}, _deployment, _lease), do: :ok

  defp rollback_service(scope, environment, deployment, lease) do
    prior = Repo.get!(Deployment, environment.active_deployment_id)

    with {:ok, _service} <-
           Workspaces.ensure_service(
             scope,
             environment.workspace_id,
             lease.id,
             "hs-app",
             service("releases/" <> prior.id, "/workspace/data", prior.source_commit)
           ),
         {:ok, _verification} <-
           verify_served(scope, environment.workspace_id, prior.source_commit),
         {:ok, _marker} <-
           command(
             scope,
             environment.workspace_id,
             lease.id,
             "mark",
             prior.id,
             prior.source_commit,
             prior.artifact_digest,
             deployment.id
           ) do
      :ok
    end
  end

  @doc "Creates an independent, integrity-checked data export. This deliberately wakes the environment."
  def backup_environment(scope, environment_id, operation_key, opts \\ []) do
    with {:ok, scope} <- execution_scope(scope, "apps:deploy"),
         {:ok, environment} <- get_environment(scope, environment_id),
         {:ok, operation_key} <- uuid(operation_key) do
      existing =
        Repo.one(
          from b in Backup,
            where:
              b.environment_id == ^environment.id and
                fragment("?->>'operation_id'", b.verification) == ^operation_key,
            limit: 1
        )

      case existing do
        %Backup{} = backup ->
          finish_backup(scope, environment, operation_key, backup)

        nil ->
          collect_backup(
            scope,
            environment,
            operation_key,
            Keyword.get(opts, :deadline, DateTime.add(DateTime.utc_now(), 600, :second))
          )
      end
    end
  end

  defp finish_backup(
         scope,
         %{release_operation_id: operation_id} = environment,
         operation_id,
         backup
       ) do
    with {:ok, lease} <- Workspaces.get_lease(scope, backup.verification["lease_id"]),
         :ok <- finish_backup_activity(scope, environment, lease),
         {:ok, _environment} <-
           Repo.transaction(fn ->
             current = lock!(Environment, environment.id, environment.org_id)

             if current.release_operation_id != operation_id,
               do: Repo.rollback(:release_in_progress)

             unwrap!(
               Repo.update(
                 Changeset.change(current,
                   release_operation_id: nil,
                   status: if(current.active_deployment_id, do: "running", else: "sleeping")
                 )
               )
             )
           end) do
      {:ok, backup}
    end
  end

  defp finish_backup(_scope, _environment, _operation_id, backup), do: {:ok, backup}

  defp finish_backup_activity(_scope, _environment, %{status: :released}), do: :ok

  defp finish_backup_activity(scope, environment, %{status: :active} = lease) do
    with :ok <- restart_current(scope, environment, lease),
         :ok <- release_activity(scope, environment.workspace_id, lease.id),
         do: :ok
  end

  defp collect_backup(scope, environment, operation_key, deadline) do
    with {:ok, environment} <-
           Repo.transaction(fn ->
             current = lock!(Environment, environment.id, environment.org_id)

             if current.release_operation_id not in [nil, operation_key],
               do: Repo.rollback(:release_in_progress)

             compare_active!(current, environment.active_deployment_id)

             unwrap!(
               Repo.update(
                 Changeset.change(current,
                   release_operation_id: operation_key,
                   status: "maintenance"
                 )
               )
             )
           end),
         {:ok, _workspace} <- Workspaces.provision_workspace(scope, environment.workspace_id),
         {:ok, lease} <-
           admit_activity(scope, environment.workspace_id, "backup:" <> operation_key, deadline),
         :ok <- install_helper(scope, environment.workspace_id, lease.id),
         {:ok, _stopped} <-
           Workspaces.stop_service(scope, environment.workspace_id, lease.id, "hs-app"),
         {:ok, backup} <- backup_under_lease(scope, environment, %{id: operation_key}, lease),
         :ok <- restart_current(scope, environment, lease),
         :ok <- release_activity(scope, environment.workspace_id, lease.id),
         {:ok, _environment} <-
           Repo.transaction(fn ->
             current = lock!(Environment, environment.id, environment.org_id)

             if current.release_operation_id != operation_key,
               do: Repo.rollback(:release_in_progress)

             unwrap!(
               Repo.update(
                 Changeset.change(current,
                   release_operation_id: nil,
                   status: if(current.active_deployment_id, do: "running", else: "sleeping")
                 )
               )
             )
           end) do
      {:ok, backup}
    end
  end

  @doc false
  def schedule_due_backups do
    now = DateTime.utc_now()

    environments =
      Repo.all(
        from e in Environment,
          where: not is_nil(e.active_deployment_id) and is_nil(e.release_operation_id),
          limit: 500
      )

    results =
      Enum.map(environments, fn environment ->
        last =
          Repo.one(
            from b in Backup,
              where: b.environment_id == ^environment.id,
              select: max(b.inserted_at)
          )

        interval = Map.get(environment.configuration, "backup_interval_hours", 24) * 3600

        if is_nil(last) or DateTime.diff(now, last, :second) >= interval do
          app = Repo.get!(App, environment.app_id)

          Hermitscale.Apps.BackupWorker.new(%{
            environment_id: environment.id,
            organization_id: app.org_id,
            actor_user_id: app.created_by_user_id,
            operation_key: Ecto.UUID.generate(),
            deadline: DateTime.to_iso8601(DateTime.add(now, 600, :second))
          })
          |> Oban.insert()
        else
          {:ok, :not_due}
        end
      end)

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil -> {:ok, :scheduled}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def perform_backup(%{
        "organization_id" => org,
        "actor_user_id" => actor,
        "environment_id" => id,
        "operation_key" => key,
        "deadline" => deadline
      }) do
    with {:ok, scope} <- execution_scope_for(org, actor, "apps:deploy"),
         {:ok, deadline, 0} <- DateTime.from_iso8601(deadline) do
      backup_environment(scope, id, key, deadline: deadline)
    end
  end

  defp backup_under_lease(scope, environment, deployment, lease) do
    with {:ok, result} <-
           command(scope, environment.workspace_id, lease.id, "backup", deployment.id),
         {:ok, content} <-
           Workspaces.read_file(scope, environment.workspace_id, lease.id, result["path"]),
         true <- digest_bytes(content) == result["digest"],
         {:ok, artifact} <-
           Artifacts.record(scope, %{
             owner_type: "app",
             owner_id: environment.app_id,
             kind: "sqlite_backup",
             content_type: "application/x-tar",
             content: content
           }),
         {:ok, backup} <-
           Repo.insert(
             Backup.changeset(
               %Backup{org_id: environment.org_id, environment_id: environment.id},
               %{
                 artifact_id: artifact.id,
                 digest: artifact.digest,
                 source_deployment_id: environment.active_deployment_id,
                 verification: Map.put(result, "lease_id", lease.id)
               }
             )
           ) do
      case Repo.get(Deployment, deployment.id) do
        nil -> :ok
        record -> Repo.update!(Changeset.change(record, backup_id: backup.id))
      end

      {:ok, backup}
    else
      false -> {:error, :backup_digest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  @doc "Records an explicit approved data-recovery operation independently of code rollback."
  def restore_data(scope, environment_id, backup_id, attrs) do
    with {:ok, scope} <- execution_scope(scope, "apps:deploy"),
         {:ok, environment} <- get_environment(scope, environment_id),
         {:ok, backup} <- get_backup(scope, backup_id),
         true <- backup.environment_id == environment.id,
         {:ok, operation_key} <- key(value(attrs, :operation_key)),
         {:ok, target} <- restore_target_digest(scope, environment.id, backup.id),
         :ok <-
           Reviews.authorize_decision(
             scope,
             value(attrs, :review_id),
             "apps.restore_data",
             target,
             1
           ) do
      Repo.transaction(fn ->
        current = lock!(Environment, environment.id, environment.org_id)
        compare_active!(current, environment.active_deployment_id)

        case Repo.get_by(DataRecovery, org_id: environment.org_id, operation_key: operation_key) do
          %DataRecovery{target_digest: ^target} = existing ->
            existing

          %DataRecovery{} ->
            Repo.rollback(:operation_key_conflict)

          nil ->
            if Repo.exists?(
                 from r in DataRecovery,
                   where:
                     r.org_id == ^environment.org_id and r.review_id == ^value(attrs, :review_id)
               ),
               do: Repo.rollback(:review_already_used)

            recovery =
              %DataRecovery{
                org_id: environment.org_id,
                environment_id: environment.id,
                backup_id: backup.id,
                execution_actor_user_id: scope.user.id
              }
              |> DataRecovery.changeset(%{
                operation_key: operation_key,
                review_id: value(attrs, :review_id),
                target_digest: target,
                expected_active_deployment_id: current.active_deployment_id,
                deadline: DateTime.add(DateTime.utc_now(), 900, :second)
              })
              |> Repo.insert()
              |> unwrap!()

            unwrap!(Oban.insert(RecoveryWorker.new(%{recovery_id: recovery.id})))
            recovery
        end
      end)
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def get_recovery(scope, id), do: fetch(scope, DataRecovery, id, "apps:read")

  @doc false
  def reconcile_recovery(id) do
    with {:ok, id} <- uuid(id),
         %DataRecovery{} = recovery <- Repo.get(DataRecovery, id),
         {:ok, scope} <-
           execution_scope_for(recovery.org_id, recovery.execution_actor_user_id, "apps:deploy") do
      case recovery.status do
        "restored" -> finish_recorded_release(scope, recovery)
        status when status in ["queued", "restoring"] -> execute_recovery(scope, recovery)
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp execute_recovery(scope, recovery) do
    with :ok <-
           Reviews.authorize_decision(
             scope,
             recovery.review_id,
             "apps.restore_data",
             recovery.target_digest,
             1
           ),
         {:ok, backup} <- get_backup(scope, recovery.backup_id),
         {:ok, environment} <-
           Repo.transaction(fn ->
             current = lock!(Environment, recovery.environment_id, recovery.org_id)
             compare_active!(current, recovery.expected_active_deployment_id)

             if current.release_operation_id not in [nil, recovery.id],
               do: Repo.rollback(:release_in_progress)

             unwrap!(
               Repo.update(
                 Changeset.change(current,
                   status: "maintenance",
                   release_operation_id: recovery.id
                 )
               )
             )
           end),
         {:ok, _workspace} <- Workspaces.provision_workspace(scope, environment.workspace_id),
         {:ok, lease} <-
           Workspaces.admit_lease(
             scope,
             environment.workspace_id,
             "recovery:" <> recovery.id,
             recovery.deadline
           ),
         {:ok, recovery} <-
           Repo.update(Changeset.change(recovery, status: "restoring", lease_id: lease.id)),
         :ok <- install_helper(scope, environment.workspace_id, lease.id),
         {:ok, _stopped} <-
           Workspaces.stop_service(scope, environment.workspace_id, lease.id, "hs-app"),
         {:ok, content} <- Artifacts.read(scope, backup.artifact_id),
         :ok <-
           Workspaces.write_file(
             scope,
             environment.workspace_id,
             lease.id,
             "incoming/" <> recovery.id <> ".backup.tar",
             content
           ),
         {:ok, result} <-
           command(
             scope,
             environment.workspace_id,
             lease.id,
             "restore",
             recovery.id,
             nil,
             backup.digest
           ),
         :ok <- restart_current(scope, environment, lease),
         {:ok, recovery} <-
           Repo.transaction(fn ->
             current = lock!(Environment, environment.id, environment.org_id)
             compare_active!(current, recovery.expected_active_deployment_id)

             if current.release_operation_id != recovery.id,
               do: Repo.rollback(:release_in_progress)

             unwrap!(
               Repo.update(
                 Changeset.change(current,
                   release_operation_id: nil,
                   status: if(current.active_deployment_id, do: "running", else: "sleeping")
                 )
               )
             )

             unwrap!(
               Repo.update(Changeset.change(recovery, status: "restored", verification: result))
             )
           end),
         :ok <- release_activity(scope, environment.workspace_id, lease.id) do
      record_log(
        scope,
        %{id: environment.app_id, org_id: environment.org_id},
        environment.id,
        environment.active_deployment_id,
        "data_recovery",
        Jason.encode!(result)
      )

      broadcast(environment.app_id)
      {:ok, recovery}
    end
  end

  def restore_target_digest(scope, environment_id, backup_id) do
    with {:ok, environment} <- get_environment(scope, environment_id),
         {:ok, backup} <- get_backup(scope, backup_id),
         true <- backup.environment_id == environment.id do
      {:ok,
       digest(%{
         action: "apps.restore_data",
         environment_id: environment.id,
         backup_id: backup.id,
         backup_digest: backup.digest,
         active_deployment_id: environment.active_deployment_id
       })}
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp restart_current(_scope, %{active_deployment_id: nil}, _lease), do: :ok

  defp restart_current(scope, environment, lease) do
    deployment = Repo.get!(Deployment, environment.active_deployment_id)

    with {:ok, _service} <-
           Workspaces.ensure_service(
             scope,
             environment.workspace_id,
             lease.id,
             "hs-app",
             service("releases/" <> deployment.id, "/workspace/data", deployment.source_commit)
           ),
         {:ok, _verified} <-
           verify_served(scope, environment.workspace_id, deployment.source_commit),
         do: :ok
  end

  @doc "Code rollback is a fresh reviewed promotion using the old artifact and current customer data."
  def request_rollback(scope, deployment_id, attrs) do
    with {:ok, prior} <- get_deployment(scope, deployment_id) do
      request_deployment(
        scope,
        prior.app_id,
        Map.merge(attrs, %{
          environment_id: prior.environment_id,
          session_id: prior.session_id,
          source_commit: prior.source_commit,
          artifact_id: prior.artifact_id,
          artifact_digest: prior.artifact_digest,
          rollback_of_id: prior.id
        })
      )
    end
  end

  @doc "Stored bounded redacted diagnostic evidence; no remote tail and no implicit wake."
  def read_logs(scope, app_id, opts \\ []) do
    with {:ok, app} <- get_app(scope, app_id) do
      batch_size = Keyword.get(opts, :limit, 100) |> min(200) |> max(1)

      query =
        from l in Log,
          where: l.app_id == ^app.id and l.org_id == ^app.org_id,
          order_by: [desc: l.inserted_at],
          limit: ^batch_size

      query =
        case Keyword.get(opts, :deployment_id) do
          nil -> query
          id -> where(query, [l], l.deployment_id == ^id)
        end

      Repo.all(query)
    end
  end

  def record_log(scope, app, environment_id, deployment_id, kind, content) do
    with :ok <- Authorization.authorize(scope, "apps:read"),
         true <- app.org_id == Scope.organization_id!(scope) do
      %Log{org_id: app.org_id, app_id: app.id, environment_id: environment_id}
      |> Log.changeset(%{deployment_id: deployment_id, kind: kind, content: redact(content)})
      |> Repo.insert()
    else
      false -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  def create_access_grant(scope, app_id, attrs) do
    with {:ok, scope} <- execution_scope(scope, "apps:write"),
         {:ok, app} <- get_app(scope, app_id),
         {:ok, resource} <- grant_resource(scope, app, attrs),
         {:ok, expires_at} <- grant_expiry(value(attrs, :expires_in, 900)) do
      grant = %AccessGrant{
        org_id: app.org_id,
        app_id: app.id,
        created_by_user_id: scope.user.id,
        preview_id: resource.preview_id,
        environment_id: resource.environment_id
      }

      with {:ok, grant} <-
             Repo.insert(
               AccessGrant.changeset(grant, %{
                 kind: value(attrs, :kind, "private"),
                 expires_at: expires_at
               })
             ),
           {:ok, url} <- access_url(grant) do
        {:ok, %{grant: grant, url: url}}
      end
    end
  end

  def revoke_access_grant(scope, grant_id) do
    with {:ok, scope} <- execution_scope(scope, "apps:write"),
         {:ok, grant} <- fetch(scope, AccessGrant, grant_id, "apps:read") do
      Repo.update(Changeset.change(grant, revoked_at: DateTime.utc_now()))
    end
  end

  def publication_target_digest(scope, environment_id, public) when is_boolean(public) do
    with {:ok, environment} <- get_environment(scope, environment_id) do
      {:ok,
       digest(%{
         action: "apps.publish",
         environment_id: environment.id,
         active_deployment_id: environment.active_deployment_id,
         public: public
       })}
    end
  end

  @doc "Public access is a separately reviewed choice tied to the currently verified deployment."
  def publish_environment(scope, environment_id, attrs) do
    public = value(attrs, :public, true)

    with {:ok, scope} <- execution_scope(scope, "apps:deploy"),
         {:ok, environment} <- get_environment(scope, environment_id),
         true <- environment.status == "running" and not is_nil(environment.active_deployment_id),
         {:ok, target} <- publication_target_digest(scope, environment.id, public),
         :ok <-
           Reviews.authorize_decision(scope, value(attrs, :review_id), "apps.publish", target, 1) do
      Repo.transaction(fn ->
        current = lock!(Environment, environment.id, environment.org_id)
        compare_active!(current, environment.active_deployment_id)
        unwrap!(Repo.update(Changeset.change(current, public: public)))
      end)
    else
      false -> {:error, :environment_not_published}
      {:error, _reason} = error -> error
    end
  end

  def public_url(scope, environment_id) do
    with {:ok, environment} <- get_environment(scope, environment_id),
         true <- environment.public,
         {:ok, host} <- gateway_host() do
      scheme =
        Application.get_env(:hermitscale, __MODULE__, []) |> Keyword.get(:gateway_scheme, "https")

      {:ok,
       scheme <>
         "://" <> environment.id <> "." <> host <> "/gateway/public-" <> environment.id <> "/"}
    else
      false -> {:error, :private_environment}
      {:error, _reason} = error -> error
    end
  end

  @doc "Validates an expiring isolated-origin grant and current owner authority before proxying."
  def resolve_access("public-" <> environment_id) do
    with {:ok, id} <- uuid(environment_id),
         %Environment{public: true, status: "running"} = environment <- Repo.get(Environment, id),
         %App{} = app <- Repo.get(App, environment.app_id),
         {:ok, scope} <- execution_scope_for(app.org_id, app.created_by_user_id, "apps:read") do
      {:ok,
       %{
         scope: scope,
         workspace_id: environment.workspace_id,
         origin_id: environment.id,
         grant: nil
       }}
    else
      nil -> {:error, :not_found}
      %Environment{} -> {:error, :environment_maintenance}
      {:error, _reason} = error -> error
    end
  end

  def resolve_access(token) do
    with {:ok, grant_id} <-
           Phoenix.Token.verify(HermitscaleWeb.Endpoint, "app-access-v1", token, max_age: 604_800),
         {:ok, grant_id} <- uuid(grant_id),
         %AccessGrant{revoked_at: nil} = grant <- Repo.get(AccessGrant, grant_id),
         true <- DateTime.compare(grant.expires_at, DateTime.utc_now()) == :gt,
         {:ok, scope} <-
           execution_scope_for(grant.org_id, grant.created_by_user_id, "apps:write"),
         {:ok, workspace_id} <- access_workspace(scope, grant) do
      {:ok,
       %{
         scope: scope,
         workspace_id: workspace_id,
         origin_id: grant.preview_id || grant.environment_id,
         grant: grant
       }}
    else
      nil -> {:error, :not_found}
      false -> {:error, :access_expired}
      %AccessGrant{} -> {:error, :access_revoked}
      {:error, _reason} = error -> error
    end
  end

  def gateway_host do
    case Application.get_env(:hermitscale, __MODULE__, []) |> Keyword.fetch(:gateway_host) do
      {:ok, host} when is_binary(host) and host != "" -> {:ok, host}
      :error -> {:error, :gateway_not_configured}
    end
  end

  defp access_url(grant) do
    with {:ok, host} <- gateway_host() do
      token = Phoenix.Token.sign(HermitscaleWeb.Endpoint, "app-access-v1", grant.id)

      scheme =
        Application.get_env(:hermitscale, __MODULE__, []) |> Keyword.get(:gateway_scheme, "https")

      origin_id = grant.preview_id || grant.environment_id
      {:ok, scheme <> "://" <> origin_id <> "." <> host <> "/gateway/" <> token <> "/"}
    end
  end

  defp grant_resource(scope, app, attrs) do
    case {value(attrs, :preview_id), value(attrs, :environment_id)} do
      {preview_id, nil} when is_binary(preview_id) ->
        with {:ok, preview} <- get_preview(scope, preview_id),
             true <- preview.app_id == app.id and preview.status == "ready" do
          {:ok, %{preview_id: preview.id, environment_id: nil}}
        else
          false -> {:error, :preview_not_ready}
          {:error, _reason} = error -> error
        end

      {nil, environment_id} when is_binary(environment_id) ->
        with {:ok, environment} <- get_environment(scope, environment_id),
             true <- environment.app_id == app.id and not is_nil(environment.active_deployment_id) do
          {:ok, %{preview_id: nil, environment_id: environment.id}}
        else
          false -> {:error, :environment_not_published}
          {:error, _reason} = error -> error
        end

      _invalid ->
        {:error, :invalid_access_resource}
    end
  end

  defp access_workspace(scope, %{preview_id: id}) when is_binary(id) do
    with {:ok, preview} <- get_preview(scope, id),
         true <- preview.status == "ready" do
      {:ok, preview.workspace_id}
    else
      false -> {:error, :preview_not_ready}
      {:error, _reason} = error -> error
    end
  end

  defp access_workspace(scope, %{environment_id: id}) do
    with {:ok, environment} <- get_environment(scope, id),
         true <- environment.status == "running" do
      {:ok, environment.workspace_id}
    else
      false -> {:error, :environment_maintenance}
      {:error, _reason} = error -> error
    end
  end

  def subscribe(scope, app_id) do
    with {:ok, app} <- get_app(scope, app_id),
         do: Phoenix.PubSub.subscribe(Hermitscale.PubSub, topic(app.id))
  end

  defp broadcast(app_id),
    do: Phoenix.PubSub.broadcast(Hermitscale.PubSub, topic(app_id), {:app_changed, app_id})

  defp topic(app_id), do: "app:" <> app_id

  def result(%Preview{} = p),
    do: %{
      "id" => p.id,
      "preview_id" => p.id,
      "app_id" => p.app_id,
      "workspace_id" => p.workspace_id,
      "source_commit" => p.source_commit,
      "status" => p.status,
      "verification" => p.verification,
      "url" =>
        HermitscaleWeb.Endpoint.url() <> "/apps/" <> p.app_id <> "/previews/" <> p.id <> "/open"
    }

  def result(%Deployment{} = d),
    do: %{
      "id" => d.id,
      "deployment_id" => d.id,
      "app_id" => d.app_id,
      "environment_id" => d.environment_id,
      "source_commit" => d.source_commit,
      "status" => d.status,
      "verification" => d.verification
    }

  defp build_session(scope, app_id, session_id) do
    with {:ok, app} <- get_app(scope, app_id),
         {:ok, session} <- Agents.get_session(scope, session_id) do
      case Repo.get_by(BuildSession, app_id: app.id, session_id: session.id, org_id: app.org_id) do
        nil -> {:error, :session_not_attached_to_app}
        %BuildSession{} -> {:ok, app, session}
      end
    end
  end

  defp attached_build(app, session_id) do
    with {:ok, session_id} <- uuid(session_id) do
      case Repo.get_by(BuildSession, app_id: app.id, session_id: session_id, org_id: app.org_id) do
        nil -> {:error, :session_not_attached_to_app}
        build -> {:ok, build}
      end
    end
  end

  defp list_owned(scope, app_id, module) do
    with {:ok, app} <- get_app(scope, app_id) do
      Repo.all(
        from r in module,
          where: r.app_id == ^app.id and r.org_id == ^app.org_id,
          order_by: [desc: r.inserted_at],
          limit: 100
      )
    end
  end

  defp environment_for(_scope, app, nil) do
    case Repo.get_by(Environment, app_id: app.id, org_id: app.org_id, name: "production") do
      nil -> {:error, :not_found}
      environment -> {:ok, environment}
    end
  end

  defp environment_for(scope, app, id) do
    with {:ok, environment} <- get_environment(scope, id) do
      case environment.app_id == app.id do
        true -> {:ok, environment}
        false -> {:error, :not_found}
      end
    end
  end

  defp source_artifact(app, artifact, requested_digest) do
    cond do
      artifact.owner_type != "app" or artifact.owner_id != app.id or
          artifact.kind != "source_bundle" ->
        {:error, :invalid_source_artifact}

      artifact.digest != requested_digest ->
        {:error, :artifact_digest_mismatch}

      true ->
        :ok
    end
  end

  defp configuration_match(environment, requested) do
    case environment.configuration_digest == requested do
      true -> :ok
      false -> {:error, :configuration_changed}
    end
  end

  defp install_helper(scope, workspace_id, lease_id) do
    path = Application.app_dir(:hermitscale, "priv/app_recipes/python_sqlite_v1/release.py")
    Workspaces.write_file(scope, workspace_id, lease_id, "app-tools/release.py", File.read!(path))
  end

  defp command(
         scope,
         workspace_id,
         lease_id,
         action,
         operation_id,
         source_commit \\ nil,
         artifact_digest \\ nil,
         previous \\ nil
       ) do
    args = [["python3", "app-tools/release.py", action, "--operation", operation_id]]
    args = List.flatten(args)
    args = if source_commit, do: args ++ ["--revision", source_commit], else: args
    args = if artifact_digest, do: args ++ ["--digest", artifact_digest], else: args
    args = if previous, do: args ++ ["--previous", previous], else: args

    with {:ok, %{exit_code: code, output: output}} <-
           Workspaces.execute_command(
             scope,
             workspace_id,
             lease_id,
             Enum.map_join(args, " ", &shell_quote/1)
           ) do
      case code do
        0 ->
          output |> String.trim() |> String.split("\n") |> List.last() |> Jason.decode()

        _failure ->
          {:error, {:recipe_command_failed, action, code, redact(output)}}
      end
    end
  end

  defp service(cwd, data_path, revision) do
    %{
      command: "python3",
      args: ["app.py", "--data-dir", data_path, "--revision", revision, "--port", "8080"],
      http_port: 8080,
      cwd: cwd
    }
  end

  defp verify_served(scope, workspace_id, expected) do
    with {:ok, response} <-
           Workspaces.app_request(scope, workspace_id, "/__hermitscale/health", method: :get),
         {:ok, body} <- decode_body(response.body) do
      case {response.status, body} do
        {200, %{"revision" => ^expected, "database" => "ok"}} ->
          {:ok,
           %{
             "served_revision" => expected,
             "health" => "passed",
             "checked_at" => DateTime.to_iso8601(DateTime.utc_now())
           }}

        {_status, _body} ->
          {:error, :served_revision_mismatch}
      end
    end
  end

  defp decode_body(body) when is_map(body), do: {:ok, body}
  defp decode_body(body) when is_binary(body), do: Jason.decode(body)

  defp release_activity(scope, workspace_id, lease_id) do
    with {:ok, evidence} <- Workspaces.termination_evidence(scope, workspace_id, lease_id),
         {:ok, _lease} <- Workspaces.release_lease(scope, lease_id, evidence),
         do: :ok
  end

  defp admit_activity(scope, workspace_id, operation_key, deadline) do
    case Workspaces.get_lease_by_operation(scope, workspace_id, operation_key) do
      {:ok, lease} -> {:ok, lease}
      {:error, :not_found} -> Workspaces.admit_lease(scope, workspace_id, operation_key, deadline)
      {:error, _reason} = error -> error
    end
  end

  defp validate_configuration(configuration) when is_map(configuration) do
    allowed = ~w(display_name backup_interval_hours)

    valid? =
      Enum.all?(configuration, fn
        {"display_name", name} when is_binary(name) -> byte_size(name) <= 120
        {"backup_interval_hours", hours} when is_integer(hours) -> hours in 1..168
        {_field, _value} -> false
      end)

    case valid? and Enum.all?(Map.keys(configuration), &(&1 in allowed)) and
           byte_size(Jason.encode!(configuration)) <= 8192 do
      true -> {:ok, configuration}
      false -> {:error, :invalid_configuration}
    end
  end

  defp validate_configuration(_configuration), do: {:error, :invalid_configuration}

  defp fetch(scope, module, id, permission) do
    with :ok <- Authorization.authorize(scope, permission),
         {:ok, id} <- uuid(id) do
      case Repo.get_by(module, id: id, org_id: Scope.organization_id!(scope)) do
        nil -> {:error, :not_found}
        record -> {:ok, record}
      end
    end
  end

  defp lock!(module, id, org_id) do
    case Repo.one(
           from r in module, where: r.id == ^id and r.org_id == ^org_id, lock: "FOR UPDATE"
         ) do
      nil -> Repo.rollback(:not_found)
      record -> record
    end
  end

  defp compare_active!(environment, expected) do
    if environment.active_deployment_id != expected, do: Repo.rollback(:active_deployment_changed)
  end

  defp execution_scope(scope, permission) do
    with :ok <- Authorization.authorize(scope, permission) do
      Authorization.execution_scope(Scope.execution_context(scope, [permission]))
    end
  end

  defp execution_scope_for(org_id, actor, permission) do
    Authorization.execution_scope(%Hermitscale.Integrations.ExecutionContext{
      organization_id: org_id,
      actor_user_id: actor,
      required_permissions: [permission]
    })
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)

  defp uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp key(key) when is_binary(key) and byte_size(key) in 1..255, do: {:ok, key}
  defp key(_key), do: {:error, :invalid_operation_key}

  defp revision(sha) when is_binary(sha) do
    case Regex.match?(~r/\A[0-9a-f]{40}\z/, sha) do
      true -> {:ok, sha}
      false -> {:error, :invalid_source_commit}
    end
  end

  defp revision(_sha), do: {:error, :invalid_source_commit}

  defp grant_expiry(seconds) when is_integer(seconds) and seconds in 1..604_800,
    do: {:ok, DateTime.add(DateTime.utc_now(), seconds, :second)}

  defp grant_expiry(_seconds), do: {:error, :invalid_access_expiry}

  defp value(attrs, field, default \\ nil),
    do: Map.get(attrs, field, Map.get(attrs, Atom.to_string(field), default))

  def digest(value), do: value |> canonical() |> :erlang.term_to_binary() |> digest_bytes()

  defp canonical(value) when is_map(value),
    do: value |> Enum.map(fn {k, v} -> {to_string(k), canonical(v)} end) |> Enum.sort()

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
  defp digest_bytes(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
  defp reason_string(reason), do: reason |> inspect(limit: 10, printable_limit: 512) |> redact()

  defp redact(content) do
    content
    |> String.slice(0, 65536)
    |> String.replace(
      ~r/(?i)(bearer\s+|(?:token|api[_-]?key|password|secret)[\"'=:\s]+)[a-z0-9_.\/-]{6,}/,
      "\\1[REDACTED]"
    )
    |> String.replace(~r/\b(?:sk-|ghp_|github_pat_)[A-Za-z0-9_-]{8,}/, "[REDACTED]")
  end
end
