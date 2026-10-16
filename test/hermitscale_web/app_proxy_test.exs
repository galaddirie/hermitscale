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
      |> post("http://demo.apps.test/api/items?q=1", ~s({"a":1}))

    assert conn.status == 201
    assert conn.resp_body == "created"
    assert get_resp_header(conn, "set-cookie") == ["theirs=2"]
  end

  test "returns 404 for unknown apps and leaves other hosts alone", %{conn: conn} do
    assert get(conn, "http://missing.apps.test/").status == 404
    assert get(conn, "http://apps.test/").status == 404
    assert get(conn, "http://nested.demo.apps.test/").status == 404
    assert get(conn, "http://www.example.com/").status == 200
  end

  test "returns 502 when the Sprite is unreachable", %{conn: conn} do
    app_fixture("demo", :public)
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))
    assert get(conn, "http://demo.apps.test/").status == 502
  end

  describe "org apps" do
    test "signs in a member and forwards their identity", %{conn: conn} do
      app = app_fixture("team", :org, "tenant:team")

      conn = get(conn, "http://team.apps.test/reports?week=1")

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
        |> get("http://team.apps.test/_hermitscale/session?" <> query)

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
        |> get("http://team.apps.test/reports?week=1")

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
        |> get("http://team.apps.test/_hermitscale/session?token=#{token}")

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
        |> get("http://team.apps.test/")

      assert conn.status == 302
      assert post(build_conn(), "http://team.apps.test/form").status == 401
    end

    test "never returns visitors to another host", %{conn: conn} do
      app_fixture("team", :org, "tenant:team")

      conn = get(conn, "http://team.apps.test//evil.example/path")

      ["https://identity.example.test/authorize?state=" <> state] =
        get_resp_header(conn, "location")

      assert {:ok, %{return_to: "/evil.example/path"}} =
               AppProxy.verify_token(:login, URI.decode_www_form(state))
    end
  end

  defp app_fixture(slug, access, org_id \\ "org_public") do
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
      sprite_url: "https://hs-#{slug}.sprites.app/"
    })
  end
end
