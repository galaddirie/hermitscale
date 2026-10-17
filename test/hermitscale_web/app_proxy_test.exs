defmodule HermitscaleWeb.AppProxyTest do
  use HermitscaleWeb.ConnCase, async: false

  alias Hermitscale.Apps.App
  alias Hermitscale.AuthTest.Provider
  alias Hermitscale.Repo
  alias Hermitscale.Workspaces.{SpritesClient, Workspace}
  alias HermitscaleWeb.AppProxy

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    previous =
      for key <- [SpritesClient, Hermitscale.Auth],
          do: {key, Application.get_env(:hermitscale, key)}

    on_exit(fn ->
      for {key, value} <- previous, do: Application.put_env(:hermitscale, key, value)
    end)

    Application.put_env(:hermitscale, SpritesClient,
      token: "sprites-test-secret",
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    Application.put_env(:hermitscale, Hermitscale.Auth, provider: Provider)
    start_supervised!({Provider, %{}})
    :ok
  end

  test "forwards public apps with the Sprite token and stripped visitor credentials", %{
    conn: conn
  } do
    app_fixture("demo", :public)

    Req.Test.expect(__MODULE__, fn upstream ->
      assert upstream.host == "hs-demo.sprites.app"
      assert {upstream.method, upstream.request_path} == {"POST", "/api/items"}
      assert upstream.query_string == "q=1"
      assert {:ok, ~s({"a":1}), upstream} = Plug.Conn.read_body(upstream)

      headers = Map.new(upstream.req_headers)
      assert headers["authorization"] == "Bearer sprites-test-secret"
      assert headers["cookie"] == "theirs=1"
      assert headers["content-type"] == "application/json"
      assert headers["x-forwarded-host"] == "demo.apps.test"
      refute Map.has_key?(headers, "x-hermitscale-user-id")

      upstream
      |> Plug.Conn.put_resp_header("set-cookie", "theirs=2")
      |> Plug.Conn.send_resp(201, "created")
    end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer visitor")
      |> put_req_cookie("_hs_app", "forged")
      |> put_req_cookie("theirs", "1")
      |> put_req_header("x-hermitscale-user-id", "spoofed")
      |> put_req_header("content-type", "application/json")
      |> app_post("http://demo.apps.test/api/items?q=1", ~s({"a":1}))

    assert conn.status == 201
    assert conn.resp_body == "created"
    assert get_resp_header(conn, "set-cookie") == ["theirs=2"]
  end

  test "returns 404 for unknown apps and other hosts", %{conn: conn} do
    assert app_get(conn, "http://missing.apps.test/").status == 404
    assert app_get(conn, "http://apps.test/").status == 404
    assert app_get(conn, "http://nested.demo.apps.test/").status == 404
    assert app_get(conn, "http://www.example.com/").status == 404
  end

  test "forwards Phoenix socket paths instead of serving Hermitscale's own", %{conn: conn} do
    app_fixture("demo", :public)
    assert HermitscaleWeb.AppsEndpoint.__sockets__() == []

    Req.Test.expect(__MODULE__, fn upstream ->
      assert upstream.request_path == "/live/longpoll"
      Plug.Conn.send_resp(upstream, 200, "app longpoll")
    end)

    assert app_get(conn, "http://demo.apps.test/live/longpoll?vsn=2.0.0").resp_body ==
             "app longpoll"
  end

  test "returns 502 when the Sprite is unreachable", %{conn: conn} do
    app_fixture("demo", :public)
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))
    assert app_get(conn, "http://demo.apps.test/").status == 502
  end

  describe "org apps" do
    test "signs in a member and forwards their identity", %{conn: conn} do
      app = app_fixture("team", :org, "tenant:team")

      conn = app_get(conn, "http://team.apps.test/reports?week=1")

      assert ["https://identity.example.test/authorize?state=" <> state] =
               get_resp_header(conn, "location")

      nonce = conn.resp_cookies["_hs_app_nonce"].value

      assert {:ok, %{app_id: app_id, return_to: "/reports?week=1"}} =
               AppProxy.verify_token(:login, URI.decode_www_form(state))

      assert app_id == app.id

      assert [{:authorization_url, [_state, [redirect_uri: redirect_uri]]}] = Provider.calls()
      assert redirect_uri =~ ~r{/apps/auth/callback$}

      callback =
        get(
          build_conn(),
          ~p"/apps/auth/callback?#{[code: "valid-code", state: URI.decode_www_form(state)]}"
        )

      assert [location] = get_resp_header(callback, "location")

      assert %URI{host: "team.apps.test", path: "/_hermitscale/session", query: query} =
               URI.parse(location)

      session =
        build_conn()
        |> put_req_cookie("_hs_app_nonce", nonce)
        |> app_get("http://team.apps.test/_hermitscale/session?" <> query)

      assert get_resp_header(session, "location") == ["/reports?week=1"]
      session_cookie = session.resp_cookies["_hs_app"]
      assert session_cookie.http_only

      Req.Test.expect(__MODULE__, fn upstream ->
        headers = Map.new(upstream.req_headers)
        assert headers["x-hermitscale-user-id"] == "person:owner"
        assert headers["x-hermitscale-user-email"] == "owner@example.test"
        refute Map.has_key?(headers, "cookie")
        Plug.Conn.send_resp(upstream, 200, "report")
      end)

      conn =
        build_conn()
        |> put_req_cookie("_hs_app", session_cookie.value)
        |> app_get("http://team.apps.test/reports?week=1")

      assert conn.resp_body == "report"
    end

    test "rejects non-members at the callback", %{conn: conn} do
      app = app_fixture("other", :org, "tenant:other")
      state = AppProxy.sign_token(:login, %{app_id: app.id, nonce: "n", return_to: "/"})

      conn = get(conn, ~p"/apps/auth/callback?#{[code: "valid-code", state: state]}")
      assert conn.status == 403
    end

    test "rejects handoffs without the matching nonce cookie", %{conn: conn} do
      app = app_fixture("team", :org, "tenant:team")
      user = %{id: "person:owner", email: nil}

      token =
        AppProxy.sign_token(:handoff, %{app_id: app.id, nonce: "n", return_to: "/", user: user})

      conn =
        conn
        |> put_req_cookie("_hs_app_nonce", "other")
        |> app_get("http://team.apps.test/_hermitscale/session?token=#{token}")

      assert conn.status == 403
    end

    test "rejects another app's session and non-GET requests without one", %{conn: conn} do
      app_fixture("team", :org, "tenant:team")
      other = app_fixture("other", :org, "tenant:team")
      user = %{id: "person:owner", email: nil}
      session = AppProxy.sign_token(:session, %{app_id: other.id, user: user})

      conn =
        conn
        |> put_req_cookie("_hs_app", session)
        |> app_get("http://team.apps.test/")

      assert conn.status == 302
      assert app_post(build_conn(), "http://team.apps.test/form").status == 401
    end

    test "never returns visitors to another host", %{conn: conn} do
      app_fixture("team", :org, "tenant:team")

      conn = app_get(conn, "http://team.apps.test//evil.example/path")

      ["https://identity.example.test/authorize?state=" <> state] =
        get_resp_header(conn, "location")

      assert {:ok, %{return_to: "/evil.example/path"}} =
               AppProxy.verify_token(:login, URI.decode_www_form(state))
    end
  end

  describe "WebSockets" do
    setup do
      upstream =
        start_supervised!(
          {Bandit,
           plug: {HermitscaleWeb.AppProxyTest.UpstreamPlug, test_pid: self()},
           ip: :loopback,
           port: 0,
           startup_log: false},
          id: :upstream
        )

      apps =
        start_supervised!(
          {Bandit, plug: HermitscaleWeb.AppsEndpoint, ip: :loopback, port: 0, startup_log: false},
          id: :apps
        )

      {:ok, {_ip, upstream_port}} = ThousandIsland.listener_info(upstream)
      {:ok, {_ip, apps_port}} = ThousandIsland.listener_info(apps)
      %{upstream_url: "http://127.0.0.1:#{upstream_port}/", apps_port: apps_port}
    end

    test "relays frames, close codes, and the subprotocol for /live/websocket", context do
      app_fixture("live", :public, "org_public", context.upstream_url)

      {conn, ref, websocket, resp_headers} =
        connect_websocket(context.apps_port, "live.apps.test", "/live/websocket?vsn=2.0.0", [
          {"sec-websocket-protocol", "phx, other"}
        ])

      assert {"sec-websocket-protocol", "phx"} in resp_headers
      assert_receive {:upstream_socket, upstream, "/live/websocket", headers}
      assert headers["authorization"] == "Bearer sprites-test-secret"
      assert headers["x-forwarded-host"] == "live.apps.test"

      {conn, websocket} = send_frame(conn, ref, websocket, {:text, "hello"})
      assert {conn, websocket, [{:text, "echo:hello"}]} = recv_frames(conn, ref, websocket)

      send(upstream, {:frames, [{:binary, <<1, 2, 3>>}]})
      assert {conn, websocket, [{:binary, <<1, 2, 3>>}]} = recv_frames(conn, ref, websocket)

      send(upstream, {:close, 4001, "bye"})
      assert {_conn, _websocket, [{:close, 4001, "bye"}]} = recv_frames(conn, ref, websocket)
    end

    test "closes the upstream socket when the visitor leaves", context do
      app_fixture("live", :public, "org_public", context.upstream_url)
      {conn, ref, websocket, _headers} = connect_websocket(context.apps_port, "live.apps.test")
      assert_receive {:upstream_socket, _upstream, "/", _headers}

      {conn, _websocket} = send_frame(conn, ref, websocket, :close)
      Mint.HTTP.close(conn)
      assert_receive {:upstream_closed, :remote}
    end

    test "only lets an org app's own pages open sockets", context do
      app = app_fixture("team", :org, "tenant:team", context.upstream_url)
      user = %{id: "person:owner", email: "owner@example.test"}

      cookie =
        {"cookie", "_hs_app=" <> AppProxy.sign_token(:session, %{app_id: app.id, user: user})}

      assert {:status, 403} =
               connect_websocket(context.apps_port, "team.apps.test", "/live/websocket", [
                 cookie,
                 {"origin", "https://evil.apps.test"}
               ])

      connect_websocket(context.apps_port, "team.apps.test", "/live/websocket", [
        cookie,
        {"origin", "http://team.apps.test"}
      ])

      assert_receive {:upstream_socket, _upstream, "/live/websocket", headers}
      assert headers["x-hermitscale-user-id"] == "person:owner"
      refute Map.has_key?(headers, "cookie")
    end
  end

  defp app_get(conn, url), do: dispatch(conn, HermitscaleWeb.AppsEndpoint, :get, url, nil)

  defp app_post(conn, url, body \\ nil),
    do: dispatch(conn, HermitscaleWeb.AppsEndpoint, :post, url, body)

  defp connect_websocket(port, host, path \\ "/", headers \\ []) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, [{"host", host} | headers])

    {:ok, conn, [{:status, ^ref, status}, {:headers, ^ref, resp_headers} | _rest]} =
      Mint.WebSocket.recv(conn, 0, 5_000)

    case status do
      101 ->
        {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, status, resp_headers)
        {conn, ref, websocket, resp_headers}

      _rejected ->
        Mint.HTTP.close(conn)
        {:status, status}
    end
  end

  defp send_frame(conn, ref, websocket, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {conn, websocket}
  end

  defp recv_frames(conn, ref, websocket) do
    {:ok, conn, responses} = Mint.WebSocket.recv(conn, 0, 5_000)
    data = for {:data, ^ref, data} <- responses, do: data
    {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, IO.iodata_to_binary(data))
    {conn, websocket, frames}
  end

  defp app_fixture(slug, access, org_id \\ "org_public", sprite_url \\ nil) do
    id = Ecto.UUID.generate()

    workspace =
      Repo.insert!(%Workspace{
        id: id,
        org_id: org_id,
        created_by_user_id: "user_1",
        name: slug,
        sprite_name: "hs-" <> String.replace(id, "-", "")
      })

    Repo.insert!(%App{
      id: Ecto.UUID.generate(),
      workspace_id: workspace.id,
      org_id: org_id,
      slug: slug,
      access: access,
      sprite_url: sprite_url || "https://hs-#{slug}.sprites.app/"
    })
  end
end
