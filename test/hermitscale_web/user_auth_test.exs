defmodule HermitscaleWeb.UserAuthTest do
  use HermitscaleWeb.ConnCase, async: false

  alias Hermitscale.WorkOS.Session
  alias Hermitscale.WorkOSTest.Client
  alias HermitscaleWeb.UserAuth

  import Hermitscale.WorkOS.SessionFixtures

  setup %{conn: conn} do
    start_supervised!({Client, %{}})
    previous_session_config = Application.get_env(:hermitscale, Hermitscale.WorkOS.Session, [])

    Application.put_env(
      :hermitscale,
      Hermitscale.WorkOS.Session,
      Keyword.put(previous_session_config, :client, Client)
    )

    on_exit(fn ->
      Application.put_env(:hermitscale, Hermitscale.WorkOS.Session, previous_session_config)
    end)

    {:ok, authentication} = Session.create(authentication_fixture())

    conn =
      conn
      |> Map.replace!(:secret_key_base, HermitscaleWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{conn: fetch_flash(conn), authentication: authentication}
  end

  test "login renews Phoenix state and writes a dedicated HttpOnly cookie", %{
    conn: conn,
    authentication: authentication
  } do
    conn = conn |> put_session(:remove_me, "value") |> UserAuth.put_workos_session(authentication)

    assert conn.resp_cookies["_hermitscale_workos"].value == authentication.sealed_session
    assert conn.resp_cookies["_hermitscale_workos"].http_only
    refute get_session(conn, :remove_me)
    assert redirected_to(conn) == "/"
  end

  test "scope is derived from verified WorkOS identity and organization", %{
    conn: conn,
    authentication: authentication
  } do
    conn =
      conn
      |> put_req_cookie("_hermitscale_workos", authentication.sealed_session)
      |> UserAuth.fetch_current_scope_for_user([])

    assert conn.assigns.current_scope.user.id == "user_workos"
    assert conn.assigns.current_scope.organization.id == "org_workos"
    assert conn.assigns.auth_session.id == "session_workos"
    refute Map.has_key?(conn.resp_cookies, "_hermitscale_workos")
  end

  test "invalid credentials are removed", %{conn: conn} do
    conn =
      conn
      |> put_req_cookie("_hermitscale_workos", "invalid")
      |> UserAuth.fetch_current_scope_for_user([])

    assert conn.assigns.current_scope == nil
    assert conn.resp_cookies["_hermitscale_workos"].max_age == 0
  end

  test "refresh rotates the browser cookie while preserving Phoenix state", %{conn: conn} do
    {:ok, authentication} =
      Session.create(authentication_fixture(%{"exp" => System.system_time(:second) + 1}))

    Client.put_response(:authenticate_with_refresh_token, {:ok, authentication_fixture()})

    conn =
      conn
      |> put_session(:preserve_me, "state")
      |> put_req_cookie("_hermitscale_workos", authentication.sealed_session)
      |> UserAuth.fetch_current_scope_for_user([])

    assert conn.assigns.current_scope.user.id == "user_workos"
    refute conn.resp_cookies["_hermitscale_workos"].value == authentication.sealed_session
    assert get_session(conn, :preserve_me) == "state"
  end

  test "refresh outage fails closed while retaining credentials for a retry", %{conn: conn} do
    {:ok, authentication} =
      Session.create(authentication_fixture(%{"exp" => System.system_time(:second) + 1}))

    Client.put_response(:authenticate_with_refresh_token, {:error, :unavailable})

    conn =
      conn
      |> put_req_cookie("_hermitscale_workos", authentication.sealed_session)
      |> UserAuth.fetch_current_scope_for_user([])

    assert conn.status == 503
    assert conn.halted
    assert conn.assigns.current_scope == nil
    refute Map.has_key?(conn.resp_cookies, "_hermitscale_workos")
  end

  test "anonymous requests receive a nil scope", %{conn: conn} do
    assert UserAuth.fetch_current_scope_for_user(conn, []).assigns.current_scope == nil
  end

  test "protected controller routes reject guests", %{conn: conn} do
    conn =
      conn
      |> assign(:current_scope, nil)
      |> fetch_flash()
      |> UserAuth.require_authenticated_user([])

    assert conn.halted
    assert redirected_to(conn) == "/auth/sign-in"
  end

  test "protected controller routes accept a verified scope", %{
    conn: conn,
    authentication: authentication
  } do
    conn =
      conn
      |> assign(:current_scope, authentication.current_scope)
      |> UserAuth.require_authenticated_user([])

    refute conn.halted
  end

  test "clear session removes cookie and Phoenix state", %{conn: conn} do
    conn = conn |> put_session(:workos_oauth_state, "pending") |> UserAuth.clear_workos_session()
    assert conn.resp_cookies["_hermitscale_workos"].max_age == 0
    refute get_session(conn, :workos_oauth_state)
  end

  test "oversized credentials fail cleanly instead of writing an unusable cookie", %{conn: conn} do
    conn = UserAuth.put_workos_session(conn, %{sealed_session: String.duplicate("x", 3_801)})
    assert redirected_to(conn) == "/"
    assert conn.resp_cookies["_hermitscale_workos"].max_age == 0
  end

  test "a large JWT still fits within the browser cookie limit", %{conn: conn} do
    authentication_response =
      authentication_fixture(%{
        "extra" => :crypto.strong_rand_bytes(1_275) |> Base.url_encode64()
      })

    assert byte_size(authentication_response["access_token"]) > 1_800
    {:ok, authentication} = Session.create(authentication_response)
    conn = UserAuth.put_workos_session(conn, authentication)
    cookie_headers = Plug.Conn.get_resp_header(conn, "set-cookie")
    assert Enum.any?(cookie_headers, &String.starts_with?(&1, "_hermitscale_workos="))
    assert Enum.all?(cookie_headers, &(byte_size(&1) <= 4_096))
  end
end
