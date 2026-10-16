defmodule Hermitscale.AppsTest do
  use Hermitscale.DataCase, async: false

  import Hermitscale.AccountsFixtures
  import Hermitscale.WorkspacesFixtures

  alias Hermitscale.Apps
  alias Hermitscale.Workspaces
  alias Hermitscale.WorkspacesTest.Client

  @sprite_url "https://hs-one-abc.sprites.app"

  setup do
    previous = Application.get_env(:hermitscale, Workspaces)
    Application.put_env(:hermitscale, Workspaces, client: Client)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:hermitscale, Workspaces)
        value -> Application.put_env(:hermitscale, Workspaces, value)
      end
    end)

    start_supervised!({Client, []})
    Client.put_response(:get, {:ok, %{"url" => @sprite_url}})
    scope = user_scope_fixture()
    %{scope: scope, workspace: workspace_fixture(scope)}
  end

  test "publishes a workspace with its Sprite URL", %{scope: scope, workspace: workspace} do
    assert {:ok, app} = Apps.create_app(scope, workspace, %{slug: "Demo"})
    assert app.slug == "demo"
    assert app.access == :org
    assert app.org_id == scope.organization.id
    assert app.sprite_url == @sprite_url
    assert Apps.app_url(app) =~ ~r{^http://demo\.apps\.test}
    assert {:ok, [^app]} = Apps.list_apps(scope)
  end

  test "validates slugs and allows one app per workspace", %{scope: scope, workspace: workspace} do
    for slug <- ["-bad", "has.dot", "www", String.duplicate("a", 64)] do
      assert {:error, changeset} = Apps.create_app(scope, workspace, %{slug: slug})
      assert %{slug: [_message]} = errors_on(changeset)
    end

    assert {:ok, _app} = Apps.create_app(scope, workspace, %{slug: "demo"})
    assert {:error, changeset} = Apps.create_app(scope, workspace, %{slug: "other"})
    assert %{workspace_id: ["already has an app"]} = errors_on(changeset)

    another = workspace_fixture(scope)
    assert {:error, changeset} = Apps.create_app(scope, another, %{slug: "demo"})
    assert %{slug: ["has already been taken"]} = errors_on(changeset)
  end

  test "updates access and slug, and unpublishes", %{scope: scope, workspace: workspace} do
    {:ok, app} = Apps.create_app(scope, workspace, %{slug: "demo"})

    assert {:ok, %{access: :public, slug: "renamed"}} =
             Apps.update_app(scope, app, %{access: "public", slug: "renamed"})

    assert {:error, changeset} = Apps.update_app(scope, app, %{access: "everyone"})
    assert %{access: ["is invalid"]} = errors_on(changeset)

    assert {:ok, _deleted} = Apps.delete_app(scope, app)
    assert {:error, :not_found} = Apps.fetch_app(scope, app.id)
  end

  test "deleting the workspace deletes its app", %{scope: scope, workspace: workspace} do
    {:ok, app} = Apps.create_app(scope, workspace, %{slug: "demo"})
    {:ok, _deleted} = Workspaces.delete_workspace(scope, workspace)
    assert Apps.get_app(app.id) == nil
  end

  test "apps are scoped to the organization and permission", %{scope: scope, workspace: workspace} do
    {:ok, app} = Apps.create_app(scope, workspace, %{slug: "demo"})
    outsider = user_scope_fixture()
    denied = put_in(scope.membership.permissions, [])

    assert {:ok, []} = Apps.list_apps(outsider)
    assert {:error, :not_found} = Apps.fetch_app(outsider, app.id)
    assert {:error, :not_found} = Apps.update_app(outsider, app, %{access: "public"})
    assert {:error, :not_found} = Apps.create_app(outsider, workspace, %{slug: "stolen"})
    assert {:error, :forbidden} = Apps.list_apps(denied)
    assert {:error, :forbidden} = Apps.create_app(denied, workspace, %{slug: "denied"})
  end
end
