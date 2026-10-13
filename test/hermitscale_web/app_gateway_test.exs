defmodule HermitscaleWeb.AppGatewayTest do
  use HermitscaleWeb.ConnCase, async: false
  import Hermitscale.AppsFixtures
  import HermitscaleWeb.BrowserAuthFixtures
  alias Hermitscale.{Apps, AppsRuntimeFake, AuthTest.Provider}
  alias HermitscaleWeb.{AppGateway, Endpoint}

  setup do
    setup_provider()
    start_supervised!({AppsRuntimeFake, []})

    for {key, value} <- [
          {:workspace_management_adapter, AppsRuntimeFake},
          {:workspace_access_adapter, AppsRuntimeFake},
          {AppGateway, [host: "apps.example.test"]}
        ] do
      previous = Application.get_env(:hermitscale, key)
      Application.put_env(:hermitscale, key, value)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:hermitscale, key, previous),
          else: Application.delete_env(:hermitscale, key)
      end)
    end

    :ok
  end

  setup %{conn: conn}, do: authenticated_conn(conn)

  setup %{scope: scope} do
    app = app_fixture(scope)
    session = app_build_fixture(scope, app)
    {:ok, _app} = Apps.ensure_preview(scope, app.id, service_attrs_fixture())
    {:ok, url} = AppGateway.open_url(scope, app.id)
    %{url: URI.parse(url), app: app, session: session}
  end

  test "authenticated app open bootstraps a host-only cookie on its isolated origin", %{
    conn: conn,
    app: app,
    url: url
  } do
    assert redirected_to(get(conn, ~p"/apps/#{app.id}/open"), 302) =~
             "https://#{url.host}/gateway/"

    bootstrap = get(%{build_conn() | host: url.host}, url.path)
    assert bootstrap.status == 302
    assert get_resp_header(bootstrap, "location") == ["/"]
    cookie = bootstrap.resp_cookies["__Host-hs_app_access"]
    assert cookie.http_only and cookie.secure and cookie.path == "/"
    refute Map.has_key?(cookie, :domain)
    assert get_resp_header(bootstrap, "referrer-policy") == ["no-referrer"]
  end

  test "proxies the original body and app cookies without platform credentials", %{
    url: url,
    session: session
  } do
    AppsRuntimeFake.app_response(%{
      status: 201,
      body: "uploaded",
      headers: %{"content-type" => ["text/plain"]}
    })

    conn =
      access_conn(url)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer ui-secret")

    conn =
      put_req_header(
        conn,
        "cookie",
        hd(get_req_header(conn, "cookie")) <> "; _hermitscale_key=ui; app_session=customer"
      )

    response = post(conn, "/notes?x=1", "body that is not JSON")
    assert response.status == 201
    assert response.resp_body == "uploaded"
    assert {:app_request, id, "/notes?x=1", options} = List.last(AppsRuntimeFake.calls())
    assert id == session.workspace_id
    assert options[:body] == "body that is not JSON"
    assert {"cookie", "app_session=customer"} in options[:headers]
    refute Enum.any?(options[:headers], fn {key, _value} -> key in ["authorization", "host"] end)
  end

  test "keeps app redirects and cookies confined to the generated origin", %{url: url} do
    AppsRuntimeFake.app_response(%{
      status: 302,
      body: "",
      headers: %{
        "location" => ["/login"],
        "set-cookie" => ["session=customer; Domain=example.test; Path=/; HttpOnly"],
        "authorization" => ["Bearer fleet"]
      }
    })

    response = get(access_conn(url), "/entry")
    assert get_resp_header(response, "location") == ["/login"]
    assert [cookie] = get_resp_header(response, "set-cookie")
    refute cookie =~ "Domain="
    assert get_resp_header(response, "authorization") == []
  end

  test "checks the selected app origin and current membership on every request", %{url: url} do
    assert get(build_conn(), url.path).status == 404

    assert get(%{build_conn() | host: Ecto.UUID.generate() <> ".apps.example.test"}, url.path).status ==
             404

    Provider.put_response(:list_memberships, {:ok, []})
    assert get(access_conn(url), "/").status == 404
  end

  test "rejects oversized uploads and expired access", %{url: url, app: app, scope: scope} do
    assert post(
             put_req_header(access_conn(url), "content-type", "application/octet-stream"),
             "/upload",
             String.duplicate("a", 1_048_577)
           ).status == 413

    expired =
      Phoenix.Token.sign(
        Endpoint,
        "private-app",
        %{
          "app_id" => app.id,
          "actor_user_id" => scope.user.id,
          "organization_id" => scope.organization.id
        },
        signed_at: 1
      )

    assert get(%{build_conn() | host: url.host}, "/gateway/" <> expired).status == 404
  end

  defp access_conn(url) do
    token = url.path |> String.split("/") |> List.last()

    %{build_conn() | host: url.host}
    |> put_req_header("cookie", "__Host-hs_app_access=" <> token)
  end
end
