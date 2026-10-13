defmodule HermitscaleWeb.AppGatewayTest do
  use HermitscaleWeb.ConnCase, async: false
  import Hermitscale.AppsFixtures
  import HermitscaleWeb.BrowserAuthFixtures
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

  setup %{scope: scope} do
    app = app_fixture(scope)
    session = app_build_fixture(scope, app)

    {:ok, preview} =
      Apps.ensure_preview(scope, app.id, %{
        session_id: session.id,
        source_commit: String.duplicate("a", 40),
        operation_key: Ecto.UUID.generate()
      })

    {:ok, %{url: url, grant: grant}} =
      Apps.create_access_grant(scope, app.id, %{preview_id: preview.id})

    %{url: url, grant: grant, app: app, session: session}
  end

  test "proxies a bounded body before UI parsers and strips UI authority", %{
    url: url,
    session: session
  } do
    AppsRuntimeFake.app_response(%{
      status: 201,
      body: "uploaded",
      headers: %{"content-type" => ["text/plain"]}
    })

    path = URI.parse(url).path <> "notes?x=1"

    conn =
      build_conn()
      |> Map.put(:host, URI.parse(url).host)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("cookie", "_hermitscale_key=private-ui; app_session=customer")
      |> put_req_header("authorization", "Bearer user-ui-secret")

    response = post(conn, path, "raw body that is not JSON")
    assert response.status == 201
    assert response.resp_body == "uploaded"
    assert {:app_request, id, "/notes?x=1", options} = List.last(AppsRuntimeFake.calls())
    assert id == session.workspace_id
    assert options[:body] == "raw body that is not JSON"
    assert {"cookie", "app_session=customer"} in options[:headers]
    refute Enum.any?(options[:headers], fn {key, _value} -> key in ["authorization", "host"] end)
    assert get_resp_header(response, "content-security-policy") |> hd() =~ "frame-ancestors"
    assert get_resp_header(response, "referrer-policy") == ["no-referrer"]
  end

  test "rewrites redirects and constrains cookies to one generated app", %{url: url} do
    AppsRuntimeFake.app_response(%{
      status: 302,
      body: "",
      headers: %{
        "location" => ["/login"],
        "set-cookie" => ["session=customer; Domain=example.com; Path=/; HttpOnly"],
        "authorization" => ["Bearer fleet"]
      }
    })

    path = URI.parse(url).path
    response = get(%{build_conn() | host: URI.parse(url).host}, path <> "entry")
    assert get_resp_header(response, "location") == ["/login"]

    cookie =
      Enum.find(get_resp_header(response, "set-cookie"), &String.starts_with?(&1, "session="))

    refute cookie =~ "Domain="
    assert cookie =~ "Path=/"
    assert cookie =~ "SameSite=Lax"
    assert cookie =~ "Secure"
    assert get_resp_header(response, "authorization") == []
  end

  test "denies main-origin access, sibling origins, revoked grants and oversized bodies", %{
    scope: scope,
    url: url,
    grant: grant
  } do
    path = URI.parse(url).path
    assert get(build_conn(), path).status == 403
    main_host = URI.parse(HermitscaleWeb.Endpoint.url()).host
    Application.put_env(:hermitscale, Apps, gateway_host: main_host)
    assert get(%{build_conn() | host: main_host}, path).status == 403
    Application.put_env(:hermitscale, Apps, gateway_host: "apps.example.test")
    assert {:ok, _grant} = Apps.revoke_access_grant(scope, grant.id)
    assert get(%{build_conn() | host: URI.parse(url).host}, path).status == 404

    {:ok, app} = Apps.get_app(scope, grant.app_id)
    [preview] = Apps.list_previews(scope, app.id)
    {:ok, %{url: fresh}} = Apps.create_access_grant(scope, app.id, %{preview_id: preview.id})

    upload_conn =
      %{build_conn() | host: URI.parse(fresh).host}
      |> put_req_header("content-type", "application/octet-stream")

    response = post(upload_conn, URI.parse(fresh).path, String.duplicate("a", 1_048_577))
    assert response.status == 413
  end

  test "bootstraps a private origin and serves absolute assets with its HttpOnly capability", %{
    url: url
  } do
    parsed = URI.parse(url)
    response = get(%{build_conn() | host: parsed.host}, parsed.path)
    assert response.status == 302
    assert get_resp_header(response, "location") == ["/"]
    cookie = response.resp_cookies["__Host-hs_app_access"]
    assert cookie.http_only
    assert cookie.secure
    assert cookie.path == "/"

    AppsRuntimeFake.app_response(%{
      status: 200,
      body: "asset",
      headers: %{"content-type" => ["text/css"]}
    })

    conn =
      %{build_conn() | host: parsed.host}
      |> put_req_header("cookie", "__Host-hs_app_access=" <> cookie.value)

    assert get(conn, "/assets/app.css").resp_body == "asset"

    assert {:app_request, _workspace_id, "/assets/app.css", options} =
             List.last(AppsRuntimeFake.calls())

    refute Enum.any?(options[:headers], fn {name, _value} -> name == "cookie" end)
    wrong_origin = %{build_conn() | host: Ecto.UUID.generate() <> ".apps.example.test"}
    assert get(wrong_origin, parsed.path).status == 403
  end

  test "WebSocket transport bounds frames, relays messages and closes revoked or idle grants", %{
    url: url,
    scope: scope,
    grant: grant
  } do
    [_gateway, token] = URI.parse(url).path |> String.split("/", trim: true)
    {:ok, access} = Apps.resolve_access(token)
    peer = start_supervised!({Hermitscale.AppSocketPeer, self()})
    AppsRuntimeFake.socket_peer(peer)
    socket = HermitscaleWeb.AppGatewaySocket

    assert {:ok, state} =
             socket.init(%{access: access, token: token, path: "/socket", headers: []})

    assert {:ok, state} = socket.handle_in({"hello", [opcode: :text]}, state)
    assert_receive {:app_socket_frame, {:text, "hello"}}

    assert {:push, {:text, "world"}, state} =
             socket.handle_info({:gun_ws, peer, state.stream, {:text, "world"}}, state)

    assert {:stop, :frame_too_large, 1009, _state} =
             socket.handle_in({String.duplicate("x", 1_048_577), [opcode: :text]}, state)

    assert {:stop, :idle, 1000, _state} =
             socket.handle_info(:check_app_access, %{
               state
               | last_activity: System.monotonic_time(:second) - 61
             })

    assert {:ok, _grant} = Apps.revoke_access_grant(scope, grant.id)
    assert {:stop, :access_expired, 1008, _state} = socket.handle_info(:check_app_access, state)
    socket.terminate(:normal, state)
  end
end
