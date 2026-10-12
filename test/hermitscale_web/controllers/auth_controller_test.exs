defmodule HermitscaleWeb.AuthControllerTest do
  use HermitscaleWeb.ConnCase, async: false

  alias Hermitscale.WorkOSTest.Client
  alias HermitscaleWeb.AuthController

  import Hermitscale.WorkOS.SessionFixtures

  setup do
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

    previous = Application.get_env(:hermitscale, AuthController, [])
    Application.put_env(:hermitscale, AuthController, Keyword.put(previous, :client, Client))
    on_exit(fn -> Application.put_env(:hermitscale, AuthController, previous) end)
  end

  test "sign-in binds state to this browser and ignores external return targets", %{conn: conn} do
    conn = get(conn, ~p"/auth/sign-in?return_to=https%3A%2F%2Fevil.example")
    assert redirected_to(conn) =~ "https://api.workos.com/authorize"
    assert %{"token" => state, "issued_at" => issued_at} = get_session(conn, :workos_oauth_state)
    assert is_integer(issued_at)
    assert [{:authorization_url, [^state, []]}] = Client.calls()
  end

  test "callback stores only sealed WorkOS credentials and renews the Phoenix session", %{
    conn: conn
  } do
    Client.put_response(:authenticate_with_code, {:ok, authentication_fixture()})
    sign_in = get(conn, ~p"/auth/sign-in")
    state = get_session(sign_in, :workos_oauth_state)["token"]

    callback =
      sign_in
      |> recycle()
      |> get(~p"/auth/workos/callback?code=code_123&state=#{state}")

    assert redirected_to(callback) == "/"

    assert %{value: sealed, http_only: true, same_site: "Lax"} =
             callback.resp_cookies["_hermitscale_workos"]

    assert is_binary(sealed)
    refute sealed =~ "refresh_secret"
    refute get_session(callback, :workos_oauth_state)
    refute get_session(callback, :auth_session_token)
    refute get_session(callback, :workos_session)
    assert callback.private.plug_session_info == :renew
  end

  test "callback rejects state from a different browser before exchanging the code", %{conn: conn} do
    sign_in = get(conn, ~p"/auth/sign-in")
    state = get_session(sign_in, :workos_oauth_state)["token"]
    callback = get(build_conn(), ~p"/auth/workos/callback?code=code_123&state=#{state}")

    assert redirected_to(callback) == "/"
    refute Map.has_key?(callback.resp_cookies, "_hermitscale_workos")
    assert [{:authorization_url, _args}] = Client.calls()
  end

  test "callback state is removed after use and cannot be replayed in that browser", %{conn: conn} do
    Client.put_response(:authenticate_with_code, {:ok, authentication_fixture()})
    sign_in = get(conn, ~p"/auth/sign-in")
    state = get_session(sign_in, :workos_oauth_state)["token"]
    callback = sign_in |> recycle() |> get(~p"/auth/workos/callback?code=code_123&state=#{state}")
    replay = callback |> recycle() |> get(~p"/auth/workos/callback?code=code_123&state=#{state}")

    assert redirected_to(replay) == "/"

    assert Enum.count(Client.calls(), fn {operation, _args} ->
             operation == :authenticate_with_code
           end) == 1

    refute get_session(replay, :workos_oauth_state)
  end

  test "expired state is rejected and removed", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{
        workos_oauth_state: %{
          "token" => "expired",
          "issued_at" => System.system_time(:second) - 601
        }
      })
      |> get(~p"/auth/workos/callback?code=code_123&state=expired")

    assert redirected_to(conn) == "/"
    assert Client.calls() == []
    refute get_session(conn, :workos_oauth_state)
  end

  test "incomplete callback clears state without authenticating", %{conn: conn} do
    sign_in = get(conn, ~p"/auth/sign-in")
    callback = sign_in |> recycle() |> get(~p"/auth/workos/callback")

    assert redirected_to(callback) == "/"
    refute get_session(callback, :workos_oauth_state)
    assert [{:authorization_url, _args}] = Client.calls()
  end

  test "failed code exchange does not establish a session", %{conn: conn} do
    Client.put_response(:authenticate_with_code, {:error, :invalid_grant})
    sign_in = get(conn, ~p"/auth/sign-in")
    state = get_session(sign_in, :workos_oauth_state)["token"]
    callback = sign_in |> recycle() |> get(~p"/auth/workos/callback?code=bad&state=#{state}")

    assert redirected_to(callback) == "/"
    refute Map.has_key?(callback.resp_cookies, "_hermitscale_workos")
    refute get_session(callback, :workos_oauth_state)
  end

  test "anonymous logout redirects through authentication", %{conn: conn} do
    conn = delete(conn, ~p"/users/log-out")
    assert redirected_to(conn) == "/auth/sign-in"
    assert Client.calls() == []
  end

  test "logout clears credentials and returns through WorkOS", %{conn: conn} do
    {:ok, authentication} = Hermitscale.WorkOS.Session.create(authentication_fixture())

    conn =
      conn
      |> put_req_cookie("_hermitscale_workos", authentication.sealed_session)
      |> delete(~p"/users/log-out")

    assert redirected_to(conn) =~ "https://api.workos.com/user_management/sessions/logout"
    assert conn.resp_cookies["_hermitscale_workos"].max_age == 0
    refute get_session(conn, :workos_oauth_state)
    assert {:revoke_session, ["session_workos"]} in Client.calls()
  end
end
