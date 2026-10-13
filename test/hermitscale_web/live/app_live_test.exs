defmodule HermitscaleWeb.AppLiveTest do
  use HermitscaleWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import HermitscaleWeb.BrowserAuthFixtures
  import Hermitscale.AppsFixtures
  alias Hermitscale.{Apps, AppsRuntimeFake}

  setup do
    setup_provider()
    start_supervised!({AppsRuntimeFake, []})
    keys = [:workspace_management_adapter, :workspace_access_adapter, Apps]
    previous = Enum.map(keys, &{&1, Application.get_env(:hermitscale, &1)})
    Application.put_env(:hermitscale, :workspace_management_adapter, AppsRuntimeFake)
    Application.put_env(:hermitscale, :workspace_access_adapter, AppsRuntimeFake)
    Application.put_env(:hermitscale, Apps, gateway_host: "apps.example.test")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:hermitscale, key)
        {key, value} -> Application.put_env(:hermitscale, key, value)
      end)
    end)

    :ok
  end

  setup %{conn: conn}, do: authenticated_conn(conn)

  test "creates an app through the form and starts its shared build conversation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/apps")
    assert has_element?(view, "#new-app-form")
    refute has_element?(view, "#apps article")
    assert AppsRuntimeFake.calls() == []

    view
    |> form("#new-app-form", app: %{name: "Research app", slug: "research-app"})
    |> render_submit()

    {path, _flash} = assert_redirect(view)
    assert path =~ "/build"
    {:ok, build, _html} = live(conn, path)
    assert has_element?(build, "#start-app-build-form")
    build |> form("#start-app-build-form") |> render_submit()
    assert has_element?(build, "#app-build-form")

    build
    |> form("#app-build-form",
      build: %{
        instructions: "Build a research dashboard",
        budget_cents: 500,
        timeout_seconds: 1800
      }
    )
    |> render_submit()

    assert has_element?(build, "#app-build-turns article")
    assert has_element?(build, "#app-build-events div")
    assert AppsRuntimeFake.calls() == []
  end

  test "prepares an immutable release and shows verified deployment evidence", %{
    conn: conn,
    scope: scope
  } do
    app = app_fixture(scope)
    _session = app_build_fixture(scope, app)
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}/build")

    view
    |> form("#app-release-form", release: %{source_commit: String.duplicate("a", 40)})
    |> render_submit()

    assert has_element?(view, "#deployment-confirmation")
    assert has_element?(view, "#confirm-app-action")
    assert Apps.list_deployments(scope, app.id) == []
    view |> element("#confirm-app-action") |> render_click()
    {path, _flash} = assert_redirect(view)
    [deployment] = Apps.list_deployments(scope, app.id)
    assert path == ~p"/apps/#{app.id}/deployments/#{deployment.id}"
    {:ok, deployment_view, _html} = live(conn, path)
    assert has_element?(deployment_view, "#deployment-status", "queued")
    assert {:ok, deployed} = Apps.reconcile_deployment(deployment.id)
    assert has_element?(deployment_view, "#deployment-status", "active")
    assert has_element?(deployment_view, "#deployment-served-revision", deployed.source_commit)
    assert has_element?(deployment_view, "#open-published-app-#{deployed.environment_id}")
    calls = AppsRuntimeFake.calls()
    {:ok, overview, _html} = live(conn, ~p"/apps/#{app.id}")
    assert has_element?(overview, "#app-deployments")
    assert has_element?(overview, "#app-logs")
    assert AppsRuntimeFake.calls() == calls
  end

  test "preview requires deliberate load and gives an isolated-origin open link", %{
    conn: conn,
    scope: scope
  } do
    app = app_fixture(scope)
    _session = app_build_fixture(scope, app)
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}/build")
    assert AppsRuntimeFake.calls() == []

    view
    |> form("#app-release-form", release: %{source_commit: String.duplicate("a", 40)})
    |> render_submit(%{"release" => %{"action" => "preview"}})

    assert has_element?(view, "#open-app-preview[target=_blank]")
    [preview] = Apps.list_previews(scope, app.id)
    assert preview.status == "ready"
    response = get(conn, ~p"/apps/#{app.id}/previews/#{preview.id}/open")
    location = response |> get_resp_header("location") |> hd()
    assert String.ends_with?(URI.parse(location).host, ".apps.example.test")
    refute has_element?(view, "iframe")
  end

  test "anonymous and cross-organization app screens are denied", %{conn: conn, scope: scope} do
    assert {:error, {:redirect, %{to: "/auth/login"}}} = live(build_conn(), ~p"/apps")
    app = app_fixture(scope)

    other = %{
      scope
      | organization: %{id: "other-org"},
        membership: %{scope.membership | org_id: "other-org"}
    }

    assert {:error, :not_found} = Apps.get_app(other, app.id)

    assert {:error, {:live_redirect, %{to: "/apps"}}} =
             live(conn, ~p"/apps/#{Ecto.UUID.generate()}")
  end
end
