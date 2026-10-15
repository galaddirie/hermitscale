defmodule Hermitscale.Workspaces do
  @moduledoc """
  Organization-owned Fly Sprites, shared by every current organization member.

  Every read and provider operation checks current membership through `Auth`.
  There are no application quotas, creator restrictions, role checks, command
  timeouts, or filesystem restrictions. Provider errors remain actionable values.

  Creation stores local intent before provisioning. On a provider failure,
  `list_workspaces/1` exposes the retained record and `refresh_workspace/2`
  reconciles it by its generated name, retrying creation only when a Sprite has
  never been provisioned and the provider confirms it is absent. A previously
  provisioned Sprite is never silently replaced with an empty filesystem.
  Deletion returns `{:error, :provisioning}` while creation is in flight or its
  outcome is uncertain; refresh reconciles that intent before deletion can proceed.
  Lifecycle calls serialize with a database row lock. Their operation errors
  commit retained intent instead of rolling it back. Retries of uncertain intent
  remain provisioning on failure because an older creation may still finish.
  Retry intent commits before the creation call, preserving it if that process crashes.
  """

  import Ecto.Query

  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Auth
  alias Hermitscale.Repo
  alias Hermitscale.Workspaces.Workspace

  @doc "Lists every workspace in the caller's active organization."
  def list_workspaces(scope) do
    with {:ok, org_id} <- authorize_member(scope) do
      workspaces =
        Workspace
        |> where([workspace], workspace.org_id == ^org_id)
        |> order_by([workspace], asc: workspace.inserted_at, asc: workspace.id)
        |> Repo.all()

      {:ok, workspaces}
    end
  end

  @doc "Fetches an organization workspace by ID; supplied structs are always refetched."
  def fetch_workspace(scope, reference) do
    with {:ok, org_id} <- authorize_member(scope) do
      fetch_for_org(org_id, reference)
    end
  end

  @doc "Retains a local provisioning intent, then creates its Sprite. Accepts name and description."
  def create_workspace(scope, attrs) do
    with {:ok, org_id} <- authorize_member(scope) do
      id = Ecto.UUID.generate()

      changeset =
        %Workspace{
          id: id,
          org_id: org_id,
          created_by_user_id: scope.user.id,
          sprite_name: "hs-" <> String.replace(id, "-", "")
        }
        |> Workspace.create_changeset(attrs)

      with {:ok, workspace} <- Repo.insert(changeset) do
        with_workspace_lock(scope, workspace, fn current ->
          provision(scope, current, current.lock_version != workspace.lock_version)
        end)
      end
    end
  end

  @doc "Refreshes provider metadata, reconciling or retrying retained provisioning intent."
  def refresh_workspace(scope, reference) do
    result = with_workspace_lock(scope, reference, &refresh_provider(scope, &1))

    case result do
      {:provision, pending, uncertain?} ->
        with_workspace_lock(scope, pending, fn current ->
          provision(scope, current, uncertain? or current.lock_version != pending.lock_version)
        end)

      {:ok, _workspace} = result ->
        result

      {:error, _reason} = result ->
        result
    end
  end

  defp refresh_provider(scope, workspace) do
    with :ok <- usable(workspace),
         {:ok, _org_id} <- authorize_member(scope) do
      case client().get(workspace.sprite_name) do
        {:ok, sprite} ->
          update_lifecycle(workspace, status: :ready, sprite_data: sprite, last_error: nil)

        {:error, :not_found} when workspace.status in [:provisioning, :failed] ->
          # Commit intent before a separate creation transaction, so a crash cannot undo it.
          with {:ok, pending} <-
                 update_lifecycle(workspace, status: :provisioning, last_error: nil) do
            {:provision, pending, workspace.status == :provisioning}
          end

        {:error, reason} ->
          retain_error(workspace, reason)
      end
    end
  end

  @doc "Deletes the remote Sprite before its local record; provisioning and failures retain intent."
  def delete_workspace(scope, reference) do
    with_workspace_lock(scope, reference, fn workspace ->
      with {:ok, deleting} <- mark_deleting(workspace),
           {:ok, _org_id} <- authorize_member(scope) do
        case client().delete(deleting.sprite_name) do
          :ok ->
            Repo.delete(deleting, stale_error_field: :lock_version)

          {:error, reason} ->
            retain_error(deleting, reason)
        end
      end
    end)
  end

  @doc "Executes a command with the provider's options and returns stdout, stderr, and exit code."
  def execute(scope, reference, command, args \\ [], opts \\ []) do
    call_sprite(scope, reference, :execute, [command, args, opts])
  end

  @doc "Starts a streaming command; the caller owns its command events and lifetime."
  def spawn(scope, reference, command, args \\ [], opts \\ []) do
    call_sprite(scope, reference, :spawn, [command, args, opts])
  end

  @doc "Lists command sessions, including detached commands."
  def list_sessions(scope, reference), do: call_sprite(scope, reference, :list_sessions, [])

  @doc "Signals a command session and returns the provider's completed progress."
  def kill_session(scope, reference, session_id, opts \\ []),
    do: call_sprite(scope, reference, :kill_session, [session_id, opts])

  @doc "Attaches to a command session; the caller owns its events and connection lifetime."
  def attach_session(scope, reference, session_id, opts \\ []),
    do: call_sprite(scope, reference, :attach_session, [session_id, opts])

  @doc "Reads bytes from any provider-supported filesystem path."
  def read_file(scope, reference, path, opts \\ []),
    do: call_sprite(scope, reference, :read_file, [path, opts])

  @doc "Writes bytes with the provider's filesystem options."
  def write_file(scope, reference, path, bytes, opts \\ []),
    do: call_sprite(scope, reference, :write_file, [path, bytes, opts])

  @doc "Lists files using the provider's options."
  def list_files(scope, reference, path, opts \\ []),
    do: call_sprite(scope, reference, :list_files, [path, opts])

  @doc "Deletes a file or directory using the provider's options."
  def delete_file(scope, reference, path, opts \\ []),
    do: call_sprite(scope, reference, :delete_file, [path, opts])

  @doc "Lists provider checkpoints."
  def list_checkpoints(scope, reference, opts \\ []),
    do: call_sprite(scope, reference, :list_checkpoints, [opts])

  @doc "Creates a checkpoint and returns completed provider progress."
  def create_checkpoint(scope, reference, opts \\ []),
    do: call_sprite(scope, reference, :create_checkpoint, [opts])

  @doc "Restores a checkpoint and returns completed provider progress."
  def restore_checkpoint(scope, reference, checkpoint_id),
    do: call_sprite(scope, reference, :restore_checkpoint, [checkpoint_id])

  @doc "Lists Sprite services."
  def list_services(scope, reference), do: call_sprite(scope, reference, :list_services, [])

  @doc "Fetches a Sprite service."
  def get_service(scope, reference, name), do: call_sprite(scope, reference, :get_service, [name])

  @doc "Creates or updates a service from provider settings."
  def put_service(scope, reference, name, attrs),
    do: call_sprite(scope, reference, :put_service, [name, attrs])

  @doc "Deletes a Sprite service."
  def delete_service(scope, reference, name),
    do: call_sprite(scope, reference, :delete_service, [name])

  @doc "Updates the Sprite URL settings."
  def update_url_settings(scope, reference, settings),
    do: call_sprite(scope, reference, :update_url_settings, [settings])

  defp call_sprite(scope, reference, operation, args) do
    with {:ok, workspace} <- fetch_workspace(scope, reference),
         :ok <- usable(workspace) do
      apply(client(), operation, [workspace.sprite_name | args])
    end
  end

  defp provision(_scope, %Workspace{status: :ready} = workspace, _uncertain?),
    do: {:ok, workspace}

  defp provision(_scope, %Workspace{status: :deleting}, _uncertain?), do: {:error, :deleting}
  defp provision(_scope, %Workspace{status: :failed}, _uncertain?), do: {:error, :conflict}

  defp provision(scope, %Workspace{status: :provisioning} = pending, uncertain?) do
    with {:ok, _org_id} <- authorize_member(scope) do
      case client().create(pending.sprite_name, []) do
        {:ok, sprite} ->
          update_lifecycle(pending, status: :ready, sprite_data: sprite, last_error: nil)

        {:error, reason} ->
          retain_error(pending, reason, provisioning_error_status(reason, uncertain?))
      end
    end
  end

  defp provisioning_error_status(_reason, true), do: :provisioning

  defp provisioning_error_status(reason, false) when reason in [:unavailable, :invalid_response],
    do: :provisioning

  defp provisioning_error_status({:unexpected_status, _status}, false), do: :provisioning
  defp provisioning_error_status(_reason, false), do: :failed

  defp mark_deleting(%Workspace{status: :provisioning}), do: {:error, :provisioning}
  defp mark_deleting(%Workspace{status: :deleting} = workspace), do: {:ok, workspace}

  defp mark_deleting(workspace),
    do: update_lifecycle(workspace, status: :deleting, last_error: nil)

  defp usable(%Workspace{status: :deleting}), do: {:error, :deleting}
  defp usable(%Workspace{}), do: :ok

  defp retain_error(workspace, reason, status \\ nil) do
    attrs = [last_error: error_metadata(reason)]
    attrs = if is_nil(status), do: attrs, else: Keyword.put(attrs, :status, status)

    with {:ok, _workspace} <- update_lifecycle(workspace, attrs) do
      {:error, reason}
    end
  end

  defp error_metadata(reason) when is_atom(reason), do: %{"code" => Atom.to_string(reason)}

  defp error_metadata({:invalid_request, status}),
    do: %{"code" => "invalid_request", "status" => status}

  defp error_metadata({:unexpected_status, status}),
    do: %{"code" => "unexpected_status", "status" => status}

  defp update_lifecycle(workspace, attrs) do
    workspace
    |> Workspace.lifecycle_changeset(attrs)
    |> Repo.update(stale_error_field: :lock_version)
    |> case do
      {:error, %{errors: [lock_version: {_message, _opts}]}} -> {:error, :conflict}
      result -> result
    end
  end

  defp authorize_member(%Scope{
         user: %{id: user_id},
         organization: %{id: org_id},
         membership: %{user_id: user_id, org_id: org_id}
       })
       when is_binary(user_id) and user_id != "" and is_binary(org_id) and org_id != "" do
    with {:ok, memberships} <- Auth.list_memberships(user_id, org_id),
         true <-
           Enum.any?(
             memberships,
             &(&1.user_id == user_id and &1.org_id == org_id and &1.status == "active")
           ) do
      {:ok, org_id}
    else
      false -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  defp authorize_member(_scope), do: {:error, :forbidden}

  defp with_workspace_lock(scope, reference, operation) do
    with {:ok, org_id} <- authorize_member(scope) do
      # Error tuples are transaction values: retained provisioning/deletion intent must commit.
      case Repo.transaction(
             fn ->
               with {:ok, workspace} <- fetch_for_org(org_id, reference, true),
                    {:ok, _org_id} <- authorize_member(scope) do
                 operation.(workspace)
               end
             end,
             timeout: :infinity
           ) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_for_org(org_id, reference, lock? \\ false)
  defp fetch_for_org(org_id, %Workspace{id: id}, lock?), do: fetch_for_org(org_id, id, lock?)

  defp fetch_for_org(org_id, id, lock?) when is_binary(id) do
    query =
      from(workspace in Workspace, where: workspace.id == ^id and workspace.org_id == ^org_id)

    query = if lock?, do: lock(query, "FOR UPDATE"), else: query

    case Repo.one(query) do
      nil -> {:error, :not_found}
      workspace -> {:ok, workspace}
    end
  end

  defp fetch_for_org(_org_id, _id, _lock?), do: {:error, :not_found}

  defp client do
    :hermitscale
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:client, Hermitscale.Workspaces.SpritesClient)
  end
end
