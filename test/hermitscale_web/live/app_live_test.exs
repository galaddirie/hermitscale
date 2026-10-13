defmodule HermitscaleWeb.AppLiveTest do
  use HermitscaleWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import HermitscaleWeb.BrowserAuthFixtures
  import Hermitscale.AppsFixtures
  import Hermitscale.ProductFixtures, only: [configure_product_fixture: 2]
  alias Hermitscale.{Apps, AppsRuntimeFake}

  setup do
    setup_provider()
    start_supervised!({AppsRuntimeFake, []})
    configure_product_fixture(:workspace_management_adapter, AppsRuntimeFake)
    configure_product_fixture(:workspace_access_adapter, AppsRuntimeFake)
    :ok
  end

  setup %{conn: conn}, do: authenticated_conn(conn)

  test "creates metadata and opens its retained coding conversation without remote work", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, ~p"/apps")
    assert has_element?(view, "#new-app-form")

    view
    |> form("#new-app-form", app: %{name: "Research app", slug: "research-app"})
    |> render_submit()

    {path, _flash} = assert_redirect(view)
    {:ok, app_view, _html} = live(conn, path)
    assert has_element?(app_view, "#start-app-build")
    app_view |> element("#start-app-build") |> render_click()
    {conversation_path, _flash} = assert_redirect(app_view)
    [app] = Apps.list_apps(scope)
    assert {:ok, current} = Apps.get_app(scope, app.id)
    assert conversation_path == ~p"/agents/#{current.session_id}"
    assert AppsRuntimeFake.calls() == []
  end

  test "viewing metadata starts nothing and service/public actions are deliberate", %{
    conn: conn,
    scope: scope
  } do
    app = app_fixture(scope)
    _session = app_build_fixture(scope, app)
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}")
    assert has_element?(view, "#app-conversation")
    assert AppsRuntimeFake.calls() == []
    refute has_element?(view, "#publish-app")

    view
    |> form("#app-service-form", service: %{start_command: "npm run start", port: 3000})
    |> render_submit()

    assert has_element?(view, "#open-private-app[target=_blank]")
    assert has_element?(view, "#publish-app")
    assert {:ok, preview} = Apps.get_app(scope, app.id)
    refute preview.public
    assert preview.port == 3000
    view |> element("#publish-app") |> render_click()
    assert has_element?(view, "#open-public-app[href=\"#{preview.native_url}\"]")
    assert {:ok, published} = Apps.get_app(scope, app.id)
    assert published.public
    view |> element("#stop-app") |> render_click()
    assert has_element?(view, "#app-service-status", "stopped")
    refute has_element?(view, "#open-public-app")
  end

  test "anonymous and foreign app screens are denied", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/login"}}} = live(build_conn(), ~p"/apps")

    assert {:error, {:live_redirect, %{to: "/apps"}}} =
             live(conn, ~p"/apps/#{Ecto.UUID.generate()}")
  end
end
