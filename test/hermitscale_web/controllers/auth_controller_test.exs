defmodule HermitscaleWeb.AuthControllerTest do
  use HermitscaleWeb.ConnCase, async: false

  alias Hermitscale.Auth
  alias Hermitscale.AuthTest.Provider
  import HermitscaleWeb.BrowserAuthFixtures

  setup do
    setup_provider()
  end

  describe "browser sign-in" do
    test "starts an OAuth transaction and establishes a verified provider session", %{conn: conn} do
      login = get(conn, ~p"/auth/login")
      state = get_session(login, :oauth_state).nonce
      assert redirected_to(login) == "https://identity.example.test/authorize?state=#{state}"

      callback = get(recycle(login), ~p"/auth/workos/callback?code=team-code&state=#{state}")
      assert redirected_to(callback) == ~p"/agents"
      assert is_binary(get_session(callback, :sealed_session))
      assert get_session(callback, :live_socket_id) == "auth_sessions:auth-session:owner"
      assert get_session(callback, :oauth_state) == nil
      assert {:ok, authentication} = Auth.authenticate(get_session(callback, :sealed_session))
      assert authentication.current_scope.organization.id == "tenant:team"
    end

    test "rejects missing or mismatched state before exchanging the code", %{conn: conn} do
      callback = get(conn, ~p"/auth/workos/callback?code=team-code&state=untrusted")
      assert redirected_to(callback) == ~p"/"
      assert get_session(callback, :sealed_session) == nil
      refute Enum.any?(Provider.calls(), fn {operation, _args} -> operation == :exchange_code end)
    end

    test "consumes a failed transaction and prevents replay", %{conn: conn} do
      login = get(conn, ~p"/auth/login")
      state = get_session(login, :oauth_state).nonce
      callback = get(recycle(login), ~p"/auth/workos/callback?code=invalid-code&state=#{state}")
      assert redirected_to(callback) == ~p"/"
      assert get_session(callback, :oauth_state) == nil

      replay = get(recycle(callback), ~p"/auth/workos/callback?code=team-code&state=#{state}")
      assert redirected_to(replay) == ~p"/"
      assert get_session(replay, :sealed_session) == nil

      assert Enum.count(Provider.calls(), fn {operation, _args} -> operation == :exchange_code end) ==
               1
    end

    test "rejects an expired transaction", %{conn: conn} do
      conn =
        init_test_session(conn, %{
          oauth_state: %{nonce: "expired", issued_at: System.system_time(:second) - 601}
        })

      callback = get(conn, ~p"/auth/workos/callback?code=team-code&state=expired")
      assert redirected_to(callback) == ~p"/"
      refute Enum.any?(Provider.calls(), fn {operation, _args} -> operation == :exchange_code end)
    end

    test "shows provider unavailability without creating a session", %{conn: conn} do
      Provider.put_response(:authorization_url, {:error, :unavailable})
      response = get(conn, ~p"/auth/login")
      assert redirected_to(response) == ~p"/"
      assert get_session(response, :oauth_state) == nil
    end

    test "rejects a provider redirect with an unsafe scheme", %{conn: conn} do
      Provider.put_response(:authorization_url, {:ok, "javascript:alert('unsafe')"})
      response = get(conn, ~p"/auth/login")
      assert redirected_to(response) == ~p"/"
      assert get_session(response, :oauth_state) == nil
    end
  end

  describe "logout" do
    test "revokes the provider session, disconnects sockets and clears the browser", %{conn: conn} do
      %{conn: conn, authentication: authentication} = authenticated_conn(conn)
      topic = Auth.socket_topic(authentication.session)
      Phoenix.PubSub.subscribe(Hermitscale.PubSub, topic)
      response = delete(conn, ~p"/auth/logout")
      assert redirected_to(response) == "https://identity.example.test/logout"
      assert get_session(response, :sealed_session) == nil
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
      assert {:error, :invalid_session} = Auth.authenticate(authentication.sealed_session)
    end

    test "clears the local session when provider revocation is unavailable", %{conn: conn} do
      %{conn: conn} = authenticated_conn(conn)
      Provider.put_response(:logout, {:error, :unavailable})
      response = delete(conn, ~p"/auth/logout")
      assert redirected_to(response) == ~p"/"
      assert get_session(response, :sealed_session) == nil
    end
  end

  test "rejects a tampered refresh handoff", %{conn: conn} do
    response = get(conn, ~p"/auth/session-refresh/untrusted")
    assert redirected_to(response) == ~p"/"
    assert get_session(response, :sealed_session) == nil
  end
end
