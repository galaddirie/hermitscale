defmodule Hermitscale.Apps do
  @moduledoc "Organization app metadata and explicit service actions in a retained coding workspace."
  import Ecto.Query
  alias Ecto.Changeset
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.{Agents, Authorization, Repo, Workspaces}
  alias Hermitscale.Apps.App

  def list_apps(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, "apps:read") do
      Repo.all(
        from app in App,
          where: app.org_id == ^Scope.organization_id!(scope),
          order_by: [desc: app.updated_at, desc: app.id],
          limit: 100
      )
    end
  end

  def get_app(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, "apps:read"), do: fetch_app(scope, id)
  end

  defp fetch_app(scope, id) do
    with {:ok, id} <- cast_id(id) do
      case Repo.get_by(App, id: id, org_id: Scope.organization_id!(scope)) do
        nil -> {:error, :not_found}
        app -> {:ok, app}
      end
    end
  end

  def change_app(%Scope{} = scope, attrs \\ %{}) do
    %App{org_id: Scope.organization_id!(scope), created_by_user_id: scope.user.id}
    |> App.changeset(attrs)
  end

  def create_app(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, scope} <- current_scope(scope, ["apps:write"]),
         {:ok, key} <- operation_key(attrs) do
      changeset = change_app(scope, attrs)

      case {key, changeset.valid?} do
        {_key, false} -> {:error, changeset}
        {nil, true} -> Repo.insert(changeset)
        {key, true} -> create_once(scope, changeset, key)
      end
    end
  end

  defp create_once(scope, changeset, key) do
    org = Scope.organization_id!(scope)
    actor = scope.user.id
    identity = :crypto.hash(:sha256, :erlang.term_to_binary({org, actor, key}, [:deterministic]))
    {:ok, id} = Ecto.UUID.load(binary_part(identity, 0, 16))
    intent = changeset |> Changeset.apply_changes() |> Map.take([:name, :slug, :repository])

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [id])

      case Repo.get(App, id) do
        nil ->
          changeset |> Changeset.put_change(:id, id) |> Repo.insert() |> unwrap!()

        %App{org_id: ^org, created_by_user_id: ^actor} = app ->
          case Map.take(app, [:name, :slug, :repository]) == intent do
            true -> app
            false -> Repo.rollback(:operation_key_conflict)
          end
      end
    end)
  end

  @doc "Returns the app's one retained coding conversation without waking its Sprite."
  def start_build(%Scope{} = scope, app_id, attrs) when is_map(attrs) do
    with {:ok, scope, app} <- owned_app(scope, app_id, ["apps:write"]) do
      Repo.transaction(fn ->
        app = Repo.one!(from a in App, where: a.id == ^app.id, lock: "FOR UPDATE")

        case app.session_id do
          nil ->
            session_attrs =
              attrs
              |> string_keys()
              |> Map.take([
                "base_sha",
                "connection_set",
                "openai_account_id",
                "github_account_id"
              ])
              |> Map.merge(%{
                "title" => app.name,
                "repository" => app.repository,
                "operation_key" => "app:" <> app.id
              })

            session = Agents.start_session(scope, session_attrs) |> unwrap!()
            app |> Changeset.change(session_id: session.id) |> Repo.update() |> unwrap!()
            session

          id ->
            app_session(scope, %{app | session_id: id}) |> unwrap!()
        end
      end)
    end
  end

  def change_service(%Scope{} = scope, app_id, attrs \\ %{}) do
    with {:ok, app} <- get_app(scope, app_id),
         :ok <- owner(scope, app),
         :ok <- Authorization.authorize(scope, "apps:write") do
      {:ok, App.service_changeset(app, attrs)}
    end
  end

  @doc "Starts the chosen command as a private native Sprite service."
  def ensure_preview(%Scope{} = scope, app_id, attrs),
    do: start_service(scope, app_id, attrs, :private, ["apps:write"])

  @doc "Explicitly starts the app and makes its native Sprite URL public."
  def publish(%Scope{} = scope, app_id, attrs),
    do: start_service(scope, app_id, attrs, :public, ["apps:write", "apps:deploy"])

  defp start_service(scope, app_id, attrs, visibility, permissions) do
    with {:ok, scope, app} <- owned_app(scope, app_id, permissions),
         service_changeset = App.service_changeset(app, attrs),
         {:ok, configured} <- Changeset.apply_action(service_changeset, :update) do
      with_workspace(scope, app, fn workspace, lease ->
        with {:ok, _url} <- Workspaces.set_app_access(scope, workspace.id, lease.id, :private),
             {:ok, service} <-
               Workspaces.start_service(scope, workspace.id, lease.id, %{
                 command: "bash",
                 args: ["-lc", configured.start_command],
                 cwd: ".",
                 port: configured.port
               }),
             {:ok, url} <- service_access(scope, workspace, lease, visibility, service.url) do
          service_changeset
          |> Changeset.change(
            native_url: url,
            source_commit: service.source_commit,
            service_status: service.status,
            public: visibility == :public
          )
          |> Repo.update()
          |> broadcast_result()
        end
      end)
    end
  end

  defp service_access(_scope, _workspace, _lease, :private, url), do: {:ok, url}

  defp service_access(scope, workspace, lease, :public, _url),
    do: Workspaces.set_app_access(scope, workspace.id, lease.id, :public)

  def stop(%Scope{} = scope, app_id) do
    with {:ok, scope, app} <- owned_app(scope, app_id, ["apps:write"]) do
      with_workspace(scope, app, fn workspace, lease ->
        with {:ok, _service} <- Workspaces.stop_service(scope, workspace.id, lease.id),
             {:ok, _url} <- Workspaces.set_app_access(scope, workspace.id, lease.id, :private) do
          app
          |> Changeset.change(service_status: "stopped", public: false)
          |> Repo.update()
          |> broadcast_result()
        end
      end)
    end
  end

  @doc "Deliberately reads a bounded snapshot of native service logs."
  def read_logs(%Scope{} = scope, app_id, opts \\ []) do
    with {:ok, scope, app} <- owned_app(scope, app_id, ["apps:write"]) do
      limit = Keyword.get(opts, :limit, 100)

      case is_integer(limit) and limit in 1..200 do
        true ->
          with_workspace(scope, app, fn workspace, lease ->
            Workspaces.service_logs(scope, workspace.id, lease.id, limit)
          end)

        false ->
          {:error, :invalid_limit}
      end
    end
  end

  @doc "Resolves an owner's app workspace for authenticated private HTTP access."
  def workspace(%Scope{} = scope, app_id) do
    with {:ok, app} <- get_app(scope, app_id),
         :ok <- owner(scope, app),
         {:ok, session} <- app_session(scope, app) do
      Workspaces.get_workspace(scope, session.workspace_id)
    end
  end

  defp with_workspace(scope, app, action) do
    with {:ok, session} <- app_session(scope, app),
         {:ok, workspace} <- Workspaces.provision_workspace(scope, session.workspace_id),
         {:ok, lease} <-
           Workspaces.admit_lease(
             scope,
             workspace.id,
             "app-service:" <> Ecto.UUID.generate(),
             DateTime.add(DateTime.utc_now(), 120, :second)
           ) do
      result = action.(workspace, lease)

      with {:ok, _lease} <- Workspaces.release_activity(scope, lease.id) do
        result
      end
    end
  end

  defp app_session(_scope, %App{session_id: nil}), do: {:error, :conversation_required}

  defp app_session(scope, %App{session_id: id}) do
    case Repo.get_by(Hermitscale.Agents.Session,
           id: id,
           org_id: Scope.organization_id!(scope),
           initiator_user_id: scope.user.id
         ) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  defp owned_app(scope, id, permissions) do
    with {:ok, scope} <- current_scope(scope, permissions),
         {:ok, app} <- fetch_app(scope, id),
         :ok <- owner(scope, app) do
      {:ok, scope, app}
    end
  end

  defp owner(%Scope{user: %{id: actor}}, %App{created_by_user_id: actor}), do: :ok
  defp owner(%Scope{}, %App{}), do: {:error, :forbidden}

  defp current_scope(scope, permissions) do
    with :ok <-
           Enum.reduce_while(permissions, :ok, fn permission, :ok ->
             case Authorization.authorize(scope, permission) do
               :ok -> {:cont, :ok}
               {:error, _reason} = error -> {:halt, error}
             end
           end) do
      Authorization.execution_scope(Scope.execution_context(scope, permissions))
    end
  end

  def subscribe(scope, app_id) do
    with {:ok, app} <- get_app(scope, app_id),
         do: Phoenix.PubSub.subscribe(Hermitscale.PubSub, "app:" <> app.id)
  end

  defp broadcast_result({:ok, app} = result) do
    Phoenix.PubSub.broadcast(Hermitscale.PubSub, "app:" <> app.id, {:app_changed, app.id})
    result
  end

  defp broadcast_result({:error, _reason} = error), do: error

  defp operation_key(attrs) do
    case Map.fetch(string_keys(attrs), "operation_key") do
      :error -> {:ok, nil}
      {:ok, key} when is_binary(key) and byte_size(key) in 8..128 -> {:ok, key}
      {:ok, _invalid} -> {:error, :invalid_operation_key}
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_identifier}
    end
  end

  defp string_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
