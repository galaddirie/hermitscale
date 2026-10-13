defmodule Hermitscale.Workspaces do
  @moduledoc """
  Organization-scoped retained workspaces, exclusive writers, and retention policy.

  Stored identity and history reads perform no remote work. Allocation and writer
  termination use a private, explicitly configured management adapter. Expiry never
  releases a writer without termination evidence; completion does not delete storage.
  """
  import Ecto.Query

  alias Hermitscale.Accounts.Scope
  alias Hermitscale.{Authorization, Repo}

  alias Hermitscale.Workspaces.{
    Lease,
    Protection,
    SpriteAccess,
    SpritesManagement,
    Workspace,
    WorkerClient,
    Recipe,
    Evidence,
    Publication
  }

  @max_lease_seconds 3600
  @max_file_bytes 1_048_576
  @max_command_bytes 8192

  @doc "Reports installed runtime versions and required configuration without attaching compute."
  def runtime_qualification, do: SpriteAccess.qualification()

  def get_lease(scope, lease_id) do
    with :ok <- authorize_activity(scope),
         {:ok, id} <- cast_id(lease_id),
         {:ok, lease} <- fetch_lease(Scope.organization_id!(scope), id),
         :ok <- validate_actor(lease, scope),
         do: {:ok, lease}
  end

  @doc "Loads a scoped operation's original writer and deadline without waking compute."
  def get_lease_by_operation(scope, workspace_id, operation_key) do
    with :ok <- authorize_activity(scope),
         {:ok, workspace} <- get_workspace(scope, workspace_id) do
      case Repo.get_by(Lease,
             workspace_id: workspace.id,
             operation_key: operation_key,
             org_id: workspace.org_id
           ) do
        nil ->
          {:error, :not_found}

        lease ->
          with :ok <- validate_actor(lease, scope), do: {:ok, lease}
      end
    end
  end

  def prepare_turn(scope, workspace_id, lease, turn, provider_env \\ %{}, options \\ []) do
    with {:ok, workspace, lease} <- resolve_access(scope, workspace_id, lease.id),
         {:ok, workspace} <- provision_workspace(scope, workspace.id),
         :ok <- revalidate_remote_authority(scope, management_adapter()) do
      Recipe.prepare(workspace, lease, turn, provider_env, options)
    end
  end

  def worker_command(scope, workspace_id, lease_id, envelope) do
    with {:ok, workspace, lease} <-
           resolve_control_access(scope, workspace_id, lease_id, envelope),
         :ok <- revalidate_remote_authority(scope, management_adapter()) do
      WorkerClient.command(workspace, lease, envelope)
    end
  end

  def termination_evidence(scope, workspace_id, lease_id) do
    with {:ok, lease} <- get_lease(scope, lease_id),
         {:ok, workspace} <- get_workspace(scope, workspace_id),
         true <- lease.workspace_id == workspace.id,
         :ok <- revalidate_remote_authority(scope, management_adapter()) do
      management_adapter().termination_evidence(workspace, lease)
    else
      false -> {:error, :lease_workspace_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def release_activity(scope, lease_id) do
    with {:ok, lease} <- get_lease(scope, lease_id) do
      case lease.status do
        :released ->
          with :ok <- release_hold(lease), do: {:ok, lease}

        :active ->
          with {:ok, proof} <- termination_evidence(scope, lease.workspace_id, lease.id),
               {:ok, released} <- release_lease(scope, lease.id, proof),
               :ok <- release_hold(lease),
               do: {:ok, released}
      end
    end
  end

  @doc "Server-side revocation cleanup. It can only stop an already admitted writer and retain its files."
  def terminate_admitted(workspace_id, lease_id) do
    with {:ok, workspace_id} <- cast_id(workspace_id),
         {:ok, lease_id} <- cast_id(lease_id),
         %Lease{workspace_id: ^workspace_id, status: :active} = lease <-
           Repo.get(Lease, lease_id),
         %Workspace{generation: generation} = workspace <- Repo.get(Workspace, workspace_id),
         true <- lease.generation == generation,
         {:ok, proof} <- management_adapter().terminate_admitted(workspace, lease),
         :ok <- release_hold(lease) do
      Repo.transaction(fn ->
        current = lock_workspace!(workspace.org_id, workspace.id)
        current_lease = Repo.get!(Lease, lease.id)
        if current.generation != lease.generation, do: Repo.rollback(:stale_generation)

        case current_lease.status do
          :active -> current_lease |> Lease.release_changeset(proof) |> update_or_rollback!()
          :released -> current_lease
        end
      end)
    else
      nil ->
        {:error, :not_found}

      %Lease{workspace_id: ^workspace_id, status: :released} = lease ->
        with :ok <- release_hold(lease), do: {:ok, lease}

      %Lease{} ->
        {:error, :lease_workspace_mismatch}

      false ->
        {:error, :stale_generation}

      {:error, _reason} = error ->
        error
    end
  end

  def delete_workspace(scope, workspace_id) do
    with {:ok, workspace} <- request_deletion(scope, workspace_id),
         :ok <- revalidate_remote_authority(scope, management_adapter()),
         {:ok, _deleted} <- management_adapter().delete(workspace) do
      Repo.transaction(fn ->
        current = lock_workspace!(workspace.org_id, workspace.id)

        current
        |> Workspace.state_changeset(%{resource_state: :deleted, compute_state: :sleeping})
        |> update_or_rollback!()
      end)
    end
  end

  def collect_evidence(scope, workspace_id, lease_id, base_sha, options \\ []) do
    with {:ok, lease} <- validate_lease(scope, lease_id, purpose: :evidence),
         {:ok, workspace} <- get_workspace(scope, workspace_id),
         true <- lease.workspace_id == workspace.id,
         :ok <- revalidate_remote_authority(scope, management_adapter()) do
      Evidence.collect(workspace, lease, base_sha, options)
    else
      false -> {:error, :lease_workspace_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def publish_branch(scope, workspace_id, lease_id, attributes) do
    access =
      if Map.get(attributes, :reconcile_only) == true,
        do: resolve_publication_read(scope, workspace_id, lease_id),
        else: resolve_access(scope, workspace_id, lease_id)

    with {:ok, workspace, lease} <- access,
         :ok <- revalidate_remote_authority(scope, management_adapter()) do
      Publication.publish(workspace, lease, attributes)
    end
  end

  def ensure_service(scope, workspace_id, lease_id, name, spec) do
    with {:ok, workspace, _lease} <- resolve_access(scope, workspace_id, lease_id),
         :ok <- validate_service_name(name),
         {:ok, spec} <- validate_service_spec(spec),
         :ok <- revalidate_remote_authority(scope, management_adapter()) do
      profile = if name == "hs-app", do: "app", else: "coder"

      service = %{
        spec
        | command: "sudo",
          args: ["-n", "/opt/hermitscale/bin/sandbox-launch", profile, spec.command | spec.args]
      }

      management_adapter().ensure_service(workspace, name, service)
    end
  end

  def inspect_service(scope, workspace_id, lease_id, name) do
    with {:ok, workspace, _lease} <- resolve_access(scope, workspace_id, lease_id),
         :ok <- validate_service_name(name),
         do: management_adapter().inspect_service(workspace, name)
  end

  def stop_service(scope, workspace_id, lease_id, name) do
    with {:ok, workspace, _lease} <- resolve_access(scope, workspace_id, lease_id),
         :ok <- validate_service_name(name),
         do: management_adapter().stop_service(workspace, name)
  end

  def checkpoint(scope, workspace_id, lease_id, comment) do
    with {:ok, workspace, lease} <- resolve_access(scope, workspace_id, lease_id),
         true <- is_binary(comment) and byte_size(comment) <= 1024,
         {:ok, _proof} <- management_adapter().termination_evidence(workspace, lease) do
      management_adapter().checkpoint(workspace, comment)
    else
      false -> {:error, :invalid_checkpoint_comment}
      {:error, _reason} = error -> error
    end
  end

  def export_artifact(scope, workspace_id, lease_id, paths)
      when is_list(paths) and length(paths) <= 100 do
    with {:ok, workspace, lease} <- resolve_access(scope, workspace_id, lease_id) do
      Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, files} ->
        with {:ok, path} <- validate_path(path),
             {:ok, content} <- access_adapter().read_file(workspace, lease, path) do
          file = %{path: path, content: Base.encode64(content), digest: Evidence.digest(content)}
          {:cont, {:ok, [file | files]}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, files} ->
          {:ok,
           %{
             files: Enum.reverse(files),
             digest: Evidence.digest(Jason.encode!(Enum.reverse(files)))
           }}

        {:error, _reason} = error ->
          error
      end
    end
  end

  def import_artifact(scope, workspace_id, lease_id, %{files: files, digest: digest}) do
    with true <- is_list(files) and length(files) <= 100,
         true <- Evidence.digest(Jason.encode!(files)) == digest do
      Enum.reduce_while(files, :ok, fn %{path: path, content: encoded, digest: hash}, :ok ->
        with {:ok, content} <- Base.decode64(encoded),
             true <- Evidence.digest(content) == hash,
             :ok <- write_file(scope, workspace_id, lease_id, path, content) do
          {:cont, :ok}
        else
          false -> {:halt, {:error, :artifact_digest_mismatch}}
          :error -> {:halt, {:error, :invalid_artifact}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      false -> {:error, :artifact_digest_mismatch}
    end
  end

  def app_request(scope, workspace_id, path, options \\ []) do
    with :ok <- Authorization.authorize(scope, "apps:read"),
         {:ok, workspace} <- get_workspace(scope, workspace_id),
         :ok <- validate_app_path(path),
         do: management_adapter().app_request(workspace, path, options)
  end

  def open_app_socket(scope, workspace_id, path, headers) do
    with :ok <- Authorization.authorize(scope, "apps:read"),
         {:ok, workspace} <- get_workspace(scope, workspace_id),
         :ok <- validate_app_path(path),
         do: management_adapter().open_app_socket(workspace, path, headers)
  end

  @doc "Explicit live read under an authorized, current lease; historical reads use stored evidence."
  def read_file(scope, workspace_id, lease_id, path) do
    with :ok <- authorize_read(scope),
         {:ok, workspace, lease} <- resolve_access(scope, workspace_id, lease_id),
         {:ok, path} <- validate_path(path) do
      access_adapter().read_file(workspace, lease, path)
    end
  end

  @doc "Writes a bounded file only under the workspace's admitted writer."
  def write_file(scope, workspace_id, lease_id, path, content) do
    with {:ok, workspace, lease} <- resolve_access(scope, workspace_id, lease_id),
         {:ok, path} <- validate_path(path),
         :ok <- validate_content(content) do
      access_adapter().write_file(workspace, lease, path, content)
    end
  end

  @doc "Runs an explicit bounded command under the admitted operation and server-owned identity."
  def execute_command(scope, workspace_id, lease_id, command) do
    with {:ok, workspace, lease} <- resolve_access(scope, workspace_id, lease_id),
         :ok <- validate_command(command) do
      access_adapter().execute_command(workspace, lease, command)
    end
  end

  @doc "Persists a stable workspace identity for an owner without creating remote compute."
  def ensure_workspace(scope, owner_key, attrs \\ %{}) do
    with :ok <- authorize_activity(scope),
         :ok <- validate_key(owner_key, :invalid_owner_key),
         :ok <- validate_attrs(attrs) do
      org_id = Scope.organization_id!(scope)
      id = Ecto.UUID.generate()

      changeset =
        Workspace.creation_changeset(
          %Workspace{
            id: id,
            org_id: org_id,
            owner_key: owner_key,
            sprite_name: "hs-" <> id,
            created_by_user_id: scope.user.id
          },
          attrs
        )

      with {:ok, _inserted} <-
             Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:org_id, :owner_key]) do
        existing = Repo.get_by!(Workspace, org_id: org_id, owner_key: owner_key)
        requested = Ecto.Changeset.apply_changes(changeset)

        case same_source?(existing, requested) do
          true -> {:ok, existing}
          false -> {:error, :owner_key_conflict}
        end
      end
    end
  end

  @doc "Loads only stored metadata; never wakes a Sprite."
  def get_workspace(scope, workspace_id) do
    with :ok <- authorize_read(scope),
         {:ok, id} <- cast_id(workspace_id) do
      fetch_workspace(Scope.organization_id!(scope), id)
    end
  end

  @doc "Reconciles allocation by retained server-owned identity through the private adapter."
  def provision_workspace(scope, workspace_id) do
    with :ok <- authorize_activity(scope),
         {:ok, id} <- cast_id(workspace_id),
         {:ok, workspace} <- fetch_workspace(Scope.organization_id!(scope), id) do
      provision(scope, workspace)
    end
  end

  @doc "Admits one bounded writer, preserving operation identity across retries."
  def admit_lease(scope, workspace_id, operation_key, deadline) do
    with :ok <- authorize_activity(scope),
         {:ok, id} <- cast_id(workspace_id),
         :ok <- validate_key(operation_key, :invalid_operation_key),
         :ok <- validate_deadline(deadline) do
      org_id = Scope.organization_id!(scope)

      Repo.transaction(fn ->
        workspace = lock_workspace!(org_id, id)
        ensure_available!(workspace)

        case Repo.get_by(Lease, workspace_id: workspace.id, operation_key: operation_key) do
          %Lease{} = lease -> reuse_lease!(lease, scope.user.id, deadline)
          nil -> admit_writer!(workspace, scope.user.id, operation_key, deadline)
        end
      end)
    end
  end

  @doc """
  Checks current writer generation and deadline without contacting remote compute.

  `lock: true` locks the workspace before reloading the lease. Inside an enclosing
  transaction the lock remains held until that transaction commits, so evidence
  acceptance cannot race with release, deletion, or a newer admitted generation.
  """
  def validate_lease(scope, lease_id, opts \\ []) do
    with :ok <- authorize_activity(scope),
         {:ok, id} <- cast_id(lease_id) do
      opts = Keyword.validate!(opts, lock: false, purpose: :activity)

      case Keyword.fetch!(opts, :lock) do
        true -> validate_locked_lease(scope, id, opts)
        false -> validate_stored_lease(scope, id, opts)
      end
    end
  end

  defp validate_stored_lease(scope, id, opts) do
    with {:ok, lease} <- fetch_lease(Scope.organization_id!(scope), id),
         :ok <- validate_actor(lease, scope),
         {:ok, workspace} <- fetch_workspace(lease.org_id, lease.workspace_id) do
      validate_lease_state(lease, workspace, opts)
    end
  end

  defp validate_locked_lease(scope, id, opts) do
    org_id = Scope.organization_id!(scope)

    Repo.transaction(fn ->
      lease =
        case fetch_lease(org_id, id) do
          {:ok, lease} -> lease
          {:error, :not_found} -> Repo.rollback(:not_found)
        end

      workspace = lock_workspace!(org_id, lease.workspace_id)
      current = Repo.get_by!(Lease, id: id, org_id: org_id)

      with :ok <- validate_actor(current, scope),
           {:ok, current} <- validate_lease_state(current, workspace, opts) do
        current
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp validate_lease_state(lease, workspace, opts) do
    cond do
      lease.generation != workspace.generation ->
        {:error, :stale_generation}

      lease.status != :active ->
        {:error, :lease_inactive}

      Keyword.fetch!(opts, :purpose) == :activity and
          DateTime.compare(lease.deadline, DateTime.utc_now()) != :gt ->
        {:error, :lease_expired}

      workspace.resource_state in [:deleting, :deleted] ->
        {:error, :workspace_unavailable}

      true ->
        {:ok, lease}
    end
  end

  @doc "Releases a writer only after independently verified, operation-bound termination."
  def release_lease(scope, lease_id, evidence) do
    with :ok <- authorize_activity(scope),
         {:ok, id} <- cast_id(lease_id),
         {:ok, lease} <- fetch_lease(Scope.organization_id!(scope), id),
         :ok <- validate_actor(lease, scope),
         :ok <- validate_evidence(lease, evidence) do
      release_verified(scope, lease, evidence)
    end
  end

  @doc "Adds a retention protection without starting or holding compute."
  def protect_workspace(scope, workspace_id, owner_key, reason) do
    with :ok <- Authorization.authorize(scope, "workspaces:write"),
         {:ok, id} <- cast_id(workspace_id) do
      org_id = Scope.organization_id!(scope)

      Repo.transaction(fn ->
        workspace = lock_workspace!(org_id, id)
        ensure_available!(workspace)

        changeset =
          Protection.changeset(
            %Protection{org_id: org_id, workspace_id: id},
            %{owner_key: owner_key, reason: reason}
          )

        _protection =
          insert_or_rollback!(changeset,
            on_conflict: :nothing,
            conflict_target: [:workspace_id, :owner_key]
          )

        existing = Repo.get_by!(Protection, workspace_id: id, owner_key: owner_key)

        case existing.reason == reason do
          true -> existing
          false -> Repo.rollback(:protection_conflict)
        end
      end)
    end
  end

  @doc "Removes an organization's retention protection under the same deletion lock."
  def remove_protection(scope, protection_id) do
    with :ok <- Authorization.authorize(scope, "workspaces:write"),
         {:ok, id} <- cast_id(protection_id) do
      org_id = Scope.organization_id!(scope)

      Repo.transaction(fn ->
        case Repo.get_by(Protection, id: id, org_id: org_id) do
          nil ->
            Repo.rollback(:not_found)

          %Protection{} = protection ->
            _workspace = lock_workspace!(org_id, protection.workspace_id)
            Repo.delete!(protection)
        end
      end)
    end
  end

  @doc "Fences explicit deletion after checking writers and retention protections."
  def request_deletion(scope, workspace_id) do
    with :ok <- Authorization.authorize(scope, "workspaces:write"),
         {:ok, id} <- cast_id(workspace_id) do
      org_id = Scope.organization_id!(scope)

      Repo.transaction(fn ->
        workspace = lock_workspace!(org_id, id)

        case workspace.resource_state do
          state when state in [:deleting, :deleted] ->
            workspace

          state when state in [:provision_pending, :retained] ->
            ensure_no_writer!(workspace)

            if Repo.exists?(from p in Protection, where: p.workspace_id == ^id),
              do: Repo.rollback(:workspace_protected)

            workspace
            |> Workspace.state_changeset(%{
              resource_state: :deleting,
              generation: workspace.generation + 1
            })
            |> update_or_rollback!()
        end
      end)
    end
  end

  defp provision(_scope, %Workspace{resource_state: :retained} = workspace), do: {:ok, workspace}

  defp provision(_scope, %Workspace{resource_state: state}) when state in [:deleting, :deleted],
    do: {:error, :workspace_unavailable}

  defp provision(scope, %Workspace{resource_state: :provision_pending} = workspace) do
    adapter = management_adapter()

    with :ok <- revalidate_remote_authority(scope, adapter),
         {:ok, %{compute_state: compute_state}} <- adapter.ensure_allocated(workspace) do
      Repo.transaction(fn ->
        current = lock_workspace!(Scope.organization_id!(scope), workspace.id)
        ensure_available!(current)

        current
        |> Workspace.state_changeset(%{resource_state: :retained, compute_state: compute_state})
        |> update_or_rollback!()
      end)
    end
  end

  defp admit_writer!(workspace, actor_id, operation_key, deadline) do
    ensure_no_writer!(workspace)

    workspace =
      workspace
      |> Workspace.state_changeset(%{generation: workspace.generation + 1})
      |> update_or_rollback!()

    %Lease{
      workspace_id: workspace.id,
      org_id: workspace.org_id,
      execution_actor_user_id: actor_id,
      generation: workspace.generation
    }
    |> Lease.creation_changeset(%{operation_key: operation_key, deadline: deadline})
    |> insert_or_rollback!()
  end

  defp reuse_lease!(%Lease{} = lease, actor_id, deadline) do
    case lease.execution_actor_user_id == actor_id and
           DateTime.compare(lease.deadline, deadline) == :eq do
      true -> lease
      false -> Repo.rollback(:lease_conflict)
    end
  end

  defp release_verified(_scope, %Lease{status: :released} = lease, evidence) do
    case lease.termination_evidence == evidence do
      true -> {:ok, lease}
      false -> {:error, :termination_conflict}
    end
  end

  defp release_verified(scope, %Lease{status: :active} = lease, evidence) do
    adapter = management_adapter()

    with {:ok, workspace} <- fetch_workspace(lease.org_id, lease.workspace_id),
         :ok <- revalidate_remote_authority(scope, adapter),
         :ok <- adapter.verify_termination(workspace, lease, evidence) do
      Repo.transaction(fn ->
        current = lock_workspace!(Scope.organization_id!(scope), workspace.id)
        current_lease = Repo.get!(Lease, lease.id)

        cond do
          current_lease.generation != current.generation ->
            Repo.rollback(:stale_generation)

          current_lease.status == :released and current_lease.termination_evidence != evidence ->
            Repo.rollback(:termination_conflict)

          current_lease.status == :released ->
            current_lease

          current_lease.status == :active ->
            current_lease
            |> Lease.release_changeset(evidence)
            |> update_or_rollback!()
        end
      end)
    end
  end

  defp validate_evidence(
         lease,
         %{
           "workspace_id" => workspace_id,
           "lease_id" => lease_id,
           "operation_key" => operation_key,
           "generation" => generation,
           "writer_stopped" => true,
           "receipt" => receipt
         } = evidence
       )
       when map_size(evidence) == 6 and is_binary(receipt) and byte_size(receipt) <= 1024 do
    cond do
      generation != lease.generation ->
        {:error, :stale_generation}

      workspace_id != lease.workspace_id or lease_id != lease.id or
          operation_key != lease.operation_key ->
        {:error, :termination_unverified}

      true ->
        :ok
    end
  end

  defp validate_evidence(_lease, _evidence), do: {:error, :termination_unverified}

  defp validate_actor(%Lease{execution_actor_user_id: actor_id}, %{user: %{id: actor_id}}),
    do: :ok

  defp validate_actor(%Lease{}, _scope), do: {:error, :lease_actor_mismatch}

  defp revalidate_remote_authority(scope, _adapter) do
    permission =
      Enum.find(
        ~w(workspaces:write agents:run agents:publish apps:write apps:deploy),
        fn permission ->
          Authorization.authorize(scope, permission) == :ok
        end
      )

    case permission do
      nil ->
        {:error, :forbidden}

      permission ->
        case Authorization.execution_scope(Scope.execution_context(scope, [permission])) do
          {:ok, _current_scope} -> :ok
          {:error, _reason} = error -> error
        end
    end
  end

  defp resolve_publication_read(scope, workspace_id, lease_id) do
    with {:ok, workspace} <- get_workspace(scope, workspace_id),
         {:ok, lease} <- get_lease(scope, lease_id),
         true <- lease.workspace_id == workspace.id do
      {:ok, workspace, lease}
    else
      false -> {:error, :lease_workspace_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_access(scope, workspace_id, lease_id) do
    with :ok <- authorize_activity(scope),
         {:ok, id} <- cast_id(workspace_id),
         {:ok, lease} <- validate_lease(scope, lease_id),
         {:ok, workspace} <- fetch_workspace(Scope.organization_id!(scope), id) do
      case lease.workspace_id == workspace.id do
        true ->
          with :ok <- revalidate_remote_authority(scope, management_adapter()),
               do: {:ok, workspace, lease}

        false ->
          {:error, :lease_workspace_mismatch}
      end
    end
  end

  defp resolve_control_access(scope, workspace_id, lease_id, envelope) do
    purpose =
      if envelope["type"] in ~w(inspect cancel read_events ack_events),
        do: :evidence,
        else: :activity

    with {:ok, lease} <- validate_lease(scope, lease_id, purpose: purpose),
         {:ok, workspace} <- get_workspace(scope, workspace_id) do
      if lease.workspace_id == workspace.id,
        do: {:ok, workspace, lease},
        else: {:error, :lease_workspace_mismatch}
    end
  end

  defp validate_service_name(name) when is_binary(name) do
    if Regex.match?(~r/\Ahs-[a-z0-9-]{1,50}\z/, name),
      do: :ok,
      else: {:error, :invalid_service_name}
  end

  defp validate_service_name(_name), do: {:error, :invalid_service_name}

  defp validate_service_spec(%{command: command, args: args, cwd: cwd} = spec)
       when is_binary(command) and is_list(args) and is_binary(cwd) do
    with :ok <- validate_command(command),
         true <-
           length(args) <= 64 and Enum.all?(args, &(is_binary(&1) and byte_size(&1) <= 8192)),
         {:ok, relative} <- if(cwd == ".", do: {:ok, ""}, else: validate_path(cwd)),
         true <- Map.get(spec, :http_port) in [nil, 8080] do
      {:ok, Map.put(spec, :cwd, Path.join("/workspace", relative))}
    else
      false -> {:error, :invalid_service_spec}
      {:error, _reason} = error -> error
    end
  end

  defp validate_service_spec(_spec), do: {:error, :invalid_service_spec}

  defp validate_app_path(path) when is_binary(path) and byte_size(path) <= 8192 do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
         not String.contains?(path, ["\\", <<0>>, "\r", "\n"]),
       do: :ok,
       else: {:error, :invalid_app_path}
  end

  defp validate_app_path(_path), do: {:error, :invalid_app_path}

  defp validate_path(path) when is_binary(path) and byte_size(path) <= 1024 do
    segments = String.split(path, "/")

    cond do
      path == "" or String.starts_with?(path, "/") ->
        {:error, :invalid_path}

      String.contains?(path, ["\\", <<0>>]) ->
        {:error, :invalid_path}

      Enum.any?(segments, &(&1 in ["..", ".", ""])) ->
        {:error, :invalid_path}

      Enum.any?(segments, &(&1 in [".hermitscale", ".env", ".codex"])) ->
        {:error, :restricted_path}

      true ->
        {:ok, path}
    end
  end

  defp validate_path(_path), do: {:error, :invalid_path}

  defp validate_content(content)
       when is_binary(content) and byte_size(content) <= @max_file_bytes,
       do: :ok

  defp validate_content(content) when is_binary(content), do: {:error, :file_too_large}
  defp validate_content(_content), do: {:error, :invalid_content}

  defp validate_command(command)
       when is_binary(command) and byte_size(command) > 0 and
              byte_size(command) <= @max_command_bytes do
    case String.contains?(command, <<0>>) do
      true -> {:error, :invalid_command}
      false -> :ok
    end
  end

  defp validate_command(_command), do: {:error, :invalid_command}

  defp validate_key(key, _reason)
       when is_binary(key) and byte_size(key) > 0 and byte_size(key) <= 255,
       do: :ok

  defp validate_key(_key, reason), do: {:error, reason}
  defp validate_attrs(attrs) when is_map(attrs), do: :ok
  defp validate_attrs(_attrs), do: {:error, :invalid_workspace_attributes}

  defp fetch_workspace(org_id, id) do
    case Repo.get_by(Workspace, id: id, org_id: org_id) do
      nil -> {:error, :not_found}
      %Workspace{} = workspace -> {:ok, workspace}
    end
  end

  defp fetch_lease(org_id, id) do
    case Repo.get_by(Lease, id: id, org_id: org_id) do
      nil -> {:error, :not_found}
      %Lease{} = lease -> {:ok, lease}
    end
  end

  defp lock_workspace!(org_id, id) do
    case Repo.one(
           from w in Workspace, where: w.id == ^id and w.org_id == ^org_id, lock: "FOR UPDATE"
         ) do
      nil -> Repo.rollback(:not_found)
      %Workspace{} = workspace -> workspace
    end
  end

  defp ensure_available!(%Workspace{resource_state: state}) when state in [:deleting, :deleted],
    do: Repo.rollback(:workspace_unavailable)

  defp ensure_available!(%Workspace{resource_state: state})
       when state in [:provision_pending, :retained],
       do: :ok

  defp ensure_no_writer!(workspace) do
    case Repo.exists?(
           from l in Lease, where: l.workspace_id == ^workspace.id and l.status == :active
         ) do
      true -> Repo.rollback(:workspace_busy)
      false -> :ok
    end
  end

  defp insert_or_rollback!(changeset, opts \\ []) do
    case Repo.insert(changeset, opts) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_or_rollback!(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp validate_deadline(%DateTime{} = deadline) do
    seconds = DateTime.diff(deadline, DateTime.utc_now(), :second)

    case seconds > 0 and seconds <= @max_lease_seconds do
      true -> :ok
      false -> {:error, :invalid_deadline}
    end
  end

  defp validate_deadline(_deadline), do: {:error, :invalid_deadline}

  defp same_source?(left, right),
    do:
      left.recipe == right.recipe and left.repository == right.repository and
        left.base_sha == right.base_sha

  defp authorize_activity(scope) do
    Enum.reduce_while(
      ~w(workspaces:write agents:run agents:publish apps:write apps:deploy),
      {:error, :forbidden},
      fn permission, error ->
        case Authorization.authorize(scope, permission) do
          :ok -> {:halt, :ok}
          {:error, :forbidden} -> {:cont, error}
        end
      end
    )
  end

  defp authorize_read(scope) do
    case Authorization.authorize(scope, "workspaces:read") do
      :ok ->
        :ok

      {:error, :forbidden} ->
        case Authorization.authorize(scope, "agents:read") do
          :ok -> :ok
          {:error, :forbidden} -> Authorization.authorize(scope, "apps:read")
        end
    end
  end

  defp access_adapter,
    do: Application.get_env(:hermitscale, :workspace_access_adapter, SpriteAccess)

  defp management_adapter,
    do: Application.get_env(:hermitscale, :workspace_management_adapter, SpritesManagement)

  defp release_hold(lease) do
    adapter = management_adapter()

    if function_exported?(adapter, :release_hold, 2) do
      workspace = Repo.get!(Workspace, lease.workspace_id)
      adapter.release_hold(workspace, lease)
    else
      :ok
    end
  end
end
