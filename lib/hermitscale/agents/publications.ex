defmodule Hermitscale.Agents.Publications do
  @moduledoc "Manifest-bound branch publication with remote commit reconciliation."
  import Ecto.Query
  alias Hermitscale.{Agents, Authorization, Repo, Workspaces}
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Agents.{Protocol, Publication, PublicationWorker}

  @deadline_seconds 300
  @known_aborts ~w(publication_key_conflict source_revision_changed branch_conflict candidate_changed manifest_not_in_candidate publication_failed publication_evidence_mismatch invalid_publication)a
  @retryable ~w(unavailable rate_limited invalid_response lease_conflict writer_active)a

  def request(scope, session_id, attrs) do
    with :ok <- Authorization.authorize(scope, "agents:publish"),
         {:ok, scope} <-
           Authorization.execution_scope(
             Scope.execution_context(scope, ["agents:read", "agents:publish"])
           ),
         {:ok, session} <- Agents.get_session(scope, session_id),
         spec = normalize(attrs),
         :ok <- validate(spec),
         {:ok, digest} <- target_digest(scope, session_id, spec) do
      case Repo.get_by(Publication, org_id: session.org_id, operation_key: spec["operation_key"]) do
        %Publication{} = existing ->
          with :ok <- same_admission(existing, session, scope, digest) do
            if terminal?(existing),
              do: {:ok, existing},
              else: admit_publication(scope, session, spec, digest)
          end

        nil ->
          admit_publication(scope, session, spec, digest)
      end
    end
  end

  defp admit_publication(scope, session, spec, digest) do
    result =
      Repo.transaction(fn ->
        cs =
          Publication.changeset(
            %Publication{
              org_id: session.org_id,
              session_id: session.id,
              execution_actor_user_id: scope.user.id
            },
            %{operation_key: spec["operation_key"], payload_digest: digest, specification: spec}
          )

        record =
          case Repo.insert(cs,
                 on_conflict: :nothing,
                 conflict_target: [:org_id, :operation_key]
               ) do
            {:ok, _} ->
              Repo.get_by!(Publication,
                org_id: session.org_id,
                operation_key: spec["operation_key"]
              )

            {:error, reason} ->
              Repo.rollback(reason)
          end

        case same_admission(record, session, scope, digest) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        if terminal?(record) do
          record
        else
          case Oban.insert(PublicationWorker.new(%{publication_id: record.id})) do
            {:ok, _} -> record
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      end)

    notify_result(result)
  end

  defp same_admission(record, session, scope, digest) do
    if record.payload_digest == digest and record.session_id == session.id and
         record.execution_actor_user_id == scope.user.id,
       do: :ok,
       else: {:error, :publication_key_conflict}
  end

  def target_digest(scope, session_id, attrs) when is_map(attrs) do
    spec = normalize(attrs)

    with {:ok, session} <- Agents.get_session(scope, session_id),
         :ok <- validate_proposal(spec),
         {:ok, artifact} <- Hermitscale.Artifacts.get(scope, spec["patch_snapshot_artifact_id"]),
         true <-
           artifact.owner_type == "session" and artifact.owner_id == session.id and
             artifact.kind == "patch_snapshot",
         {:ok, snapshot} when is_map(snapshot) <- Jason.decode(artifact.content),
         true <-
           snapshot["base_sha"] == spec["base_sha"] and
             Protocol.payload_digest(Map.take(snapshot, ~w(base_sha diff files))) ==
               spec["candidate_digest"] do
      target =
        Map.take(
          spec,
          ~w(branch base_sha manifest message patch_snapshot_artifact_id candidate_digest)
        )
        |> Map.put("session_id", session.id)

      {:ok, Protocol.payload_digest(target)}
    else
      false -> {:error, :publication_evidence_mismatch}
      {:ok, _invalid_snapshot} -> {:error, :publication_evidence_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def get(scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      case Repo.get_by(Publication, id: id, org_id: Scope.organization_id!(scope)) do
        nil -> {:error, :not_found}
        record -> with {:ok, _} <- Agents.get_session(scope, record.session_id), do: {:ok, record}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  @doc "Reads retained publication outcomes for the initiating actor without waking compute."
  def list_for_session(scope, session_id) do
    with {:ok, session} <- Agents.get_session(scope, session_id) do
      Repo.all(
        from publication in Publication,
          where:
            publication.org_id == ^session.org_id and publication.session_id == ^session.id and
              publication.execution_actor_user_id == ^scope.user.id,
          order_by: [desc: publication.inserted_at, desc: publication.id],
          limit: 100
      )
    end
  end

  @doc "Returns the latest owner-recorded publication baseline while preserving initial session admission."
  def current_base_sha(scope, session_id) do
    with {:ok, session} <- Agents.get_session(scope, session_id) do
      publication =
        Repo.one(
          from publication in Publication,
            join: lease in Hermitscale.Workspaces.Lease,
            on: lease.id == publication.lease_id,
            where:
              publication.org_id == ^session.org_id and publication.session_id == ^session.id and
                (publication.status == :succeeded or lease.status == :released) and
                (fragment("?->>'verified'", publication.result) == "true" or
                   (lease.status == :released and
                      fragment("?->'local_receipt'->>'verified'", publication.error) == "false")),
            order_by: [desc: lease.generation],
            limit: 1
        )

      case publication do
        %Publication{result: %{"verified" => true, "commit_sha" => sha}} -> {:ok, sha}
        %Publication{error: %{"local_receipt" => %{"local_commit" => sha}}} -> {:ok, sha}
        nil -> {:ok, session.base_sha}
      end
    end
  end

  def reconcile(scope, id) do
    with :ok <- Authorization.authorize(scope, "agents:publish"),
         {:ok, scope} <-
           Authorization.execution_scope(
             Scope.execution_context(scope, ["agents:read", "agents:publish"])
           ),
         {:ok, record} <- get(scope, id),
         {:ok, session} <- Agents.get_session(scope, record.session_id) do
      cond do
        terminal?(record) ->
          {:ok, record}

        verified_result?(record) ->
          finish_verified(record)

        is_binary(record.error && record.error["known_abort"]) ->
          finish_abort(record, record.error["known_abort"])

        record.error && record.error["reconciliation_only"] == true ->
          reconcile_expired(scope, session, record)

        expired?(record) ->
          reconcile_expired(scope, session, record)

        true ->
          reconcile_active(scope, session, record)
      end
    end
  end

  defp reconcile_active(scope, session, record) do
    with {:ok, credential} <- credential(scope, session),
         {:ok, lease} <- lease(scope, session, record),
         {:ok, current} <- store(record, status: :running, lease_id: lease.id) do
      if terminal?(current) do
        {:ok, current}
      else
        case publish(scope, session, lease, current, credential, false) do
          {:ok, result} ->
            with {:ok, retained} <- store(current, result: result), do: finish_verified(retained)

          {:error, reason} ->
            handle_failure(current, reason)
        end
      end
    else
      {:error, reason} -> handle_failure(record, reason)
    end
  end

  defp reconcile_expired(_scope, _session, %Publication{lease_id: nil} = record),
    do: finish_abort(record, "publication_deadline_expired")

  defp reconcile_expired(scope, session, record) do
    with {:ok, _lease} <- cleanup_admitted(record),
         {:ok, credential} <- credential(scope, session),
         {:ok, lease} <- Workspaces.get_lease(scope, record.lease_id),
         {:ok, result} <- publish(scope, session, lease, record, credential, true),
         {:ok, retained} <- store(record, result: result) do
      finish_verified(retained)
    else
      {:error, {:publication_uncertain, _receipt} = reason} ->
        with {:ok, retained} <- handle_failure(record, reason),
             do: store(retained, error: Map.put(retained.error, "reconciliation_only", true))

      {:error, reason} ->
        store(record,
          status: :uncertain,
          error: %{"reason" => inspect(reason), "reconciliation_only" => true}
        )
    end
  end

  defp credential(scope, session),
    do:
      Hermitscale.Integrations.ExecutionAccess.credential(scope, session, "github", ["repo"], [
        "agents:publish"
      ])

  defp handle_failure(
         record,
         {:publication_uncertain,
          %{"local_commit" => sha, "base_sha" => sha, "verified" => false} = receipt}
       )
       when is_binary(sha) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha) do
      store(record,
        status: :uncertain,
        error: %{
          "reason" => ":publication_uncertain",
          "local_receipt" => Map.take(receipt, ~w(local_commit base_sha verified))
        }
      )
    else
      store(record,
        status: :uncertain,
        error: %{"reason" => ":invalid_local_publication_receipt"}
      )
    end
  end

  defp handle_failure(record, reason) do
    cond do
      reason in @known_aborts ->
        finish_abort(record, inspect(reason))

      record.lease_id == nil and reason in @retryable ->
        {:error, reason}

      record.lease_id == nil ->
        with {:ok, _retained} <- store(record, error: %{"reason" => inspect(reason)}),
             do: {:error, reason}

      true ->
        store(record, status: :uncertain, error: %{"reason" => inspect(reason)})
    end
  end

  defp finish_verified(record) do
    case cleanup_admitted(record) do
      {:ok, _lease} ->
        store(record, status: :succeeded, error: nil)

      {:error, reason} ->
        store(record,
          status: :uncertain,
          error: %{"reason" => inspect(reason), "verified_result_retained" => true}
        )
    end
  end

  defp finish_abort(record, reason) do
    case cleanup_admitted(record) do
      {:ok, _lease} ->
        store(record, status: :failed, error: %{"reason" => reason})

      {:error, pending} ->
        store(record,
          status: :uncertain,
          error: %{"reason" => inspect(pending), "known_abort" => reason}
        )
    end
  end

  @doc false
  def terminate(id, reason) do
    case Repo.get(Publication, id) do
      nil ->
        {:error, :not_found}

      record ->
        cond do
          terminal?(record) ->
            {:ok, record}

          verified_result?(record) ->
            finish_verified(record)

          is_binary(record.error && record.error["known_abort"]) ->
            finish_abort(record, record.error["known_abort"])

          record.lease_id == nil ->
            finish_abort(record, reason)

          true ->
            case cleanup_admitted(record) do
              {:ok, _lease} ->
                store(record,
                  status: :uncertain,
                  error: %{"reason" => reason, "reconciliation_only" => true}
                )

              {:error, pending} ->
                store(record,
                  status: :uncertain,
                  error: %{"reason" => inspect(pending), "reconciliation_only" => true}
                )
            end
        end
    end
  end

  defp cleanup_admitted(%Publication{lease_id: nil}), do: {:ok, nil}

  defp cleanup_admitted(record) do
    session = Repo.get!(Hermitscale.Agents.Session, record.session_id)
    Workspaces.terminate_admitted(session.workspace_id, record.lease_id)
  end

  defp verified_result?(%Publication{result: %{"verified" => true, "commit_sha" => sha}}),
    do: is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}\z/, sha)

  defp verified_result?(_record), do: false
  defp terminal?(record), do: record.status in [:succeeded, :failed]
  defp deadline(record), do: DateTime.add(record.inserted_at, @deadline_seconds)
  defp expired?(record), do: DateTime.compare(deadline(record), DateTime.utc_now()) != :gt

  def identity(id) do
    case Repo.get(Publication, id) do
      nil ->
        {:error, :not_found}

      r ->
        {:ok,
         %Hermitscale.Integrations.ExecutionContext{
           organization_id: r.org_id,
           actor_user_id: r.execution_actor_user_id,
           required_permissions: ["agents:read", "agents:publish"]
         }}
    end
  end

  defp lease(scope, session, %Publication{lease_id: nil} = record),
    do:
      Workspaces.admit_lease(
        scope,
        session.workspace_id,
        "publish:" <> record.id,
        deadline(record)
      )

  defp lease(scope, _session, record), do: Workspaces.get_lease(scope, record.lease_id)

  defp publish(scope, session, lease, record, credential, reconcile_only) do
    spec = record.specification
    # The credential remains in a transient askpass file, never a Git URL or command text.
    with {:ok, result} <-
           Workspaces.publish_branch(scope, session.workspace_id, lease.id, %{
             repository: "github:" <> session.repository,
             base_sha: spec["base_sha"],
             branch: spec["branch"],
             manifest: spec["manifest"],
             message: spec["message"],
             operation_id: record.id,
             candidate_digest: spec["candidate_digest"],
             reconcile_only: reconcile_only,
             credential: credential
           }) do
      result = Map.new(result, fn {k, v} -> {to_string(k), v} end)

      if result["repository"] == "github:" <> session.repository and
           result["branch"] == spec["branch"] and result["base_sha"] == spec["base_sha"] and
           result["manifest"] == spec["manifest"] and
           verified_result?(%Publication{result: result}),
         do: {:ok, Map.put(result, "repository", session.repository)},
         else: {:error, :publication_result_mismatch}
    end
  end

  defp store(record, attrs) do
    Repo.transaction(fn ->
      current = Repo.one!(from p in Publication, where: p.id == ^record.id, lock: "FOR UPDATE")

      attrs = retain_local_receipt(current, attrs)

      if terminal?(current),
        do: current,
        else: current |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end)
    |> notify_result()
  end

  defp retain_local_receipt(%Publication{error: %{"local_receipt" => receipt}}, attrs) do
    case Keyword.fetch(attrs, :error) do
      {:ok, %{} = error} ->
        Keyword.put(attrs, :error, Map.put_new(error, "local_receipt", receipt))

      _unchanged_or_verified ->
        attrs
    end
  end

  defp retain_local_receipt(_record, attrs), do: attrs

  defp notify_result({:ok, record} = result) do
    Phoenix.PubSub.broadcast(
      Hermitscale.PubSub,
      "agent_sessions:" <> record.session_id,
      {:agent_session_updated, record.session_id}
    )

    Hermitscale.Workflows.ExternalOperations.notify("publication", record.id)
    result
  end

  defp notify_result({:error, _reason} = error), do: error

  defp validate(%{"operation_key" => key} = spec)
       when is_binary(key) and byte_size(key) in 8..128,
       do: validate_proposal(spec)

  defp validate(_spec), do: {:error, :invalid_publication}

  defp validate_proposal(%{
         "branch" => branch,
         "base_sha" => base,
         "manifest" => manifest,
         "message" => message,
         "candidate_digest" => candidate,
         "patch_snapshot_artifact_id" => artifact
       })
       when is_binary(branch) and is_binary(base) and is_list(manifest) and
              is_binary(message) and is_binary(candidate) and is_binary(artifact) do
    if Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_\/-]{0,200}\z/, branch) and
         not String.contains?(branch, ["..", "//"]) and
         Regex.match?(~r/\A[0-9a-f]{40}\z/, base) and manifest != [] and
         Regex.match?(~r/\A[0-9a-f]{64}\z/, candidate) and
         Enum.all?(manifest, fn p ->
           is_binary(p) and p != "" and not String.starts_with?(p, ["/", "-"]) and
             not String.contains?(p, ["..", <<0>>, ".env", ".hermitscale"])
         end) and byte_size(message) in 1..4096,
       do: :ok,
       else: {:error, :invalid_publication}
  end

  defp validate_proposal(_spec), do: {:error, :invalid_publication}

  defp normalize(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    case Map.fetch(attrs, "patch_snapshot_artifact_id") do
      {:ok, _id} -> attrs
      :error -> Map.put(attrs, "patch_snapshot_artifact_id", attrs["patch_artifact_id"])
    end
  end
end
