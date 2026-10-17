defmodule Hermitscale.Apps do
  @moduledoc """
  Apps publish a workspace's HTTP service at `https://<slug>.<apps domain>`.

  Scoped functions require the `workflows:run` permission and only reach apps in
  the caller's organization. `get_app_by_slug/1` and `get_app/1` are unscoped
  lookups for `HermitscaleWeb.AppProxy`, which enforces each app's access.
  """

  import Ecto.Query

  alias Hermitscale.Apps.App
  alias Hermitscale.Auth
  alias Hermitscale.Authorization
  alias Hermitscale.Repo
  alias Hermitscale.Workspaces

  @permission "workflows:run"

  @doc "Lists the apps in the caller's organization."
  def list_apps(scope) do
    with :ok <- Authorization.authorize(scope, @permission) do
      apps =
        App
        |> where([app], app.org_id == ^scope.organization.id)
        |> order_by([app], asc: app.slug)
        |> Repo.all()

      {:ok, apps}
    end
  end

  @doc "Fetches an app by ID or struct; structs are always refetched."
  def fetch_app(scope, reference) do
    with :ok <- Authorization.authorize(scope, @permission) do
      case Repo.get_by(App, id: app_id(reference), org_id: scope.organization.id) do
        nil -> {:error, :not_found}
        app -> {:ok, app}
      end
    end
  end

  @doc """
  Publishes a workspace's HTTP service. Accepts `slug` and `access` (`:org`, the
  default, or `:public`). The workspace's Sprite URL stays private; the proxy
  authenticates to it.
  """
  def create_app(scope, workspace_reference, attrs) do
    with {:ok, workspace} <- Workspaces.fetch_workspace(scope, workspace_reference),
         {:ok, %{"url" => sprite_url}} <- Workspaces.get_sprite(scope, workspace) do
      %App{
        id: Ecto.UUID.generate(),
        workspace_id: workspace.id,
        org_id: workspace.org_id,
        sprite_url: sprite_url
      }
      |> App.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc "Changes an app's `slug` or `access`. Takes effect on the next request."
  def update_app(scope, reference, attrs) do
    with {:ok, app} <- fetch_app(scope, reference) do
      app
      |> App.changeset(attrs)
      |> Repo.update()
    end
  end

  @doc "Unpublishes an app. The workspace and its service are untouched."
  def delete_app(scope, reference) do
    with {:ok, app} <- fetch_app(scope, reference) do
      Repo.delete(app)
    end
  end

  @doc """
  Exchanges a sign-in code and returns `%{id: id, email: email}` when the user is
  an active member of the app's organization.
  """
  def sign_in_visitor(%App{org_id: org_id}, code, metadata \\ %{}) do
    with {:ok, %{current_scope: %{user: user}}} <- Auth.exchange_code(code, metadata),
         {:ok, memberships} <- Auth.list_memberships(user.id, org_id) do
      case Enum.any?(memberships, &(&1.org_id == org_id and &1.status == "active")) do
        true -> {:ok, Map.take(user, [:id, :email])}
        false -> {:error, :forbidden}
      end
    end
  end

  @doc "The app's public URL."
  def app_url(%App{slug: slug}) do
    %URI{HermitscaleWeb.AppsEndpoint.struct_url() | host: "#{slug}.#{domain()}"}
    |> URI.to_string()
  end

  @doc "The apps domain, such as `hermitscale.app`, or nil when apps are disabled."
  def domain, do: Application.get_env(:hermitscale, __MODULE__, [])[:domain]

  @doc false
  def get_app_by_slug(slug), do: Repo.get_by(App, slug: slug)

  @doc false
  def get_app(id), do: Repo.get(App, id)

  defp app_id(%App{id: id}), do: id
  defp app_id(id) when is_binary(id), do: id
end
