defmodule Hermitscale.Workspaces do
  @moduledoc """
  Organization-owned Fly Sprites.

  A workspace is a Postgres record naming one Sprite. Every operation requires
  the `workflows:run` permission and only reaches workspaces in the caller's
  organization. Sprite state (sleep, files, services, checkpoints) lives on the
  Sprite and is read from the provider when needed.
  """

  import Ecto.Query

  alias Hermitscale.Authorization
  alias Hermitscale.Repo
  alias Hermitscale.Workspaces.Workspace

  @permission "workflows:run"

  @doc "Lists the workspaces in the caller's organization."
  def list_workspaces(scope) do
    with :ok <- Authorization.authorize(scope, @permission) do
      workspaces =
        Workspace
        |> where([workspace], workspace.org_id == ^scope.organization.id)
        |> order_by([workspace], asc: workspace.inserted_at, asc: workspace.id)
        |> Repo.all()

      {:ok, workspaces}
    end
  end

  @doc "Fetches a workspace by ID or struct; structs are always refetched."
  def fetch_workspace(scope, reference) do
    with :ok <- Authorization.authorize(scope, @permission) do
      fetch_for_org(scope.organization.id, reference)
    end
  end

  @doc """
  Creates a Sprite, then records it. Accepts `name` and `description`.

  If the provider's response is lost after it created the Sprite, no record is
  stored and the `hs-` prefixed Sprite is orphaned.
  """
  def create_workspace(scope, attrs) do
    with :ok <- Authorization.authorize(scope, @permission),
         {:ok, workspace} <- build_workspace(scope, attrs),
         {:ok, _sprite} <- client().create(workspace.sprite_name) do
      Repo.insert(workspace)
    end
  end

  @doc "Deletes the Sprite, then its record. A missing Sprite counts as deleted."
  def delete_workspace(scope, reference) do
    with {:ok, workspace} <- fetch_workspace(scope, reference),
         :ok <- client().delete(workspace.sprite_name) do
      Repo.delete(workspace)
    end
  end

  @doc "Fetches live provider metadata, including the `cold`, `warm`, or `running` status."
  def get_sprite(scope, reference), do: call_sprite(scope, reference, :get, [])

  @doc "Runs a command to completion and returns stdout, stderr, and exit code."
  def execute(scope, reference, command, args \\ [], opts \\ []),
    do: call_sprite(scope, reference, :execute, [command, args, opts])

  @doc "Starts a streaming command whose events are sent to the caller or `:owner`."
  def spawn(scope, reference, command, args \\ [], opts \\ []),
    do: call_sprite(scope, reference, :spawn, [command, args, opts])

  @doc "Lists command sessions, including detached ones."
  def list_sessions(scope, reference), do: call_sprite(scope, reference, :list_sessions, [])

  @doc "Signals a command session."
  def kill_session(scope, reference, session_id, opts \\ []),
    do: call_sprite(scope, reference, :kill_session, [session_id, opts])

  @doc "Reads a file's bytes."
  def read_file(scope, reference, path), do: call_sprite(scope, reference, :read_file, [path])

  @doc "Writes bytes to a file. Accepts `:mode` and `:mkdir`."
  def write_file(scope, reference, path, bytes, opts \\ []),
    do: call_sprite(scope, reference, :write_file, [path, bytes, opts])

  @doc "Lists a directory."
  def list_files(scope, reference, path), do: call_sprite(scope, reference, :list_files, [path])

  @doc "Deletes a file, or a directory with `recursive: true`."
  def delete_file(scope, reference, path, opts \\ []),
    do: call_sprite(scope, reference, :delete_file, [path, opts])

  @doc "Lists checkpoints."
  def list_checkpoints(scope, reference), do: call_sprite(scope, reference, :list_checkpoints, [])

  @doc "Creates a checkpoint. Accepts `:comment`."
  def create_checkpoint(scope, reference, opts \\ []),
    do: call_sprite(scope, reference, :create_checkpoint, [opts])

  @doc "Restores a checkpoint, replacing the Sprite's filesystem."
  def restore_checkpoint(scope, reference, checkpoint_id),
    do: call_sprite(scope, reference, :restore_checkpoint, [checkpoint_id])

  @doc "Lists services."
  def list_services(scope, reference), do: call_sprite(scope, reference, :list_services, [])

  @doc "Fetches a service."
  def get_service(scope, reference, name), do: call_sprite(scope, reference, :get_service, [name])

  @doc "Creates or updates a service from provider attributes."
  def put_service(scope, reference, name, attrs),
    do: call_sprite(scope, reference, :put_service, [name, attrs])

  @doc "Deletes a service."
  def delete_service(scope, reference, name),
    do: call_sprite(scope, reference, :delete_service, [name])

  @doc "Updates the Sprite URL settings, such as `%{auth: \"public\"}`."
  def update_url_settings(scope, reference, settings),
    do: call_sprite(scope, reference, :update_url_settings, [settings])

  defp call_sprite(scope, reference, operation, args) do
    with {:ok, workspace} <- fetch_workspace(scope, reference) do
      apply(client(), operation, [workspace.sprite_name | args])
    end
  end

  defp build_workspace(scope, attrs) do
    id = Ecto.UUID.generate()

    %Workspace{
      id: id,
      org_id: scope.organization.id,
      created_by_user_id: scope.user.id,
      sprite_name: "hs-" <> String.replace(id, "-", "")
    }
    |> Workspace.create_changeset(attrs)
    |> Ecto.Changeset.apply_action(:insert)
  end

  defp fetch_for_org(org_id, %Workspace{id: id}), do: fetch_for_org(org_id, id)

  defp fetch_for_org(org_id, id) when is_binary(id) do
    case Repo.get_by(Workspace, id: id, org_id: org_id) do
      nil -> {:error, :not_found}
      workspace -> {:ok, workspace}
    end
  end

  defp client do
    :hermitscale
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:client, Hermitscale.Workspaces.SpritesClient)
  end
end
