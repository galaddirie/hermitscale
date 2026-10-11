defmodule HermitscaleWeb.UserAuthTest do
  use HermitscaleWeb.ConnCase, async: true

  alias Hermitscale.WorkOS.Session
  alias HermitscaleWeb.UserAuth

  import Hermitscale.AccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    local_session = workos_session_fixture(user)

    conn =
      conn
      |> Map.replace!(:secret_key_base, HermitscaleWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{conn: conn, user: user, local_session: local_session}
  end

  describe "put_workos_session/4" do
    test "renews the cookie session and stores only the opaque handle", %{
      conn: conn,
      local_session: local_session
    } do
      conn =
        conn
        |> put_session(:remove_me, "value")
        |> UserAuth.put_workos_session(
          local_session.handle,
          local_session.session,
          "/users/settings"
        )

      assert get_session(conn, :auth_session_token) == local_session.handle
      assert get_session(conn, :live_socket_id) == Session.socket_topic(local_session.session)
      refute get_session(conn, :user_token)
      refute get_session(conn, :remove_me)
      assert redirected_to(conn) == "/users/settings"
    end
  end

  describe "fetch_current_scope_for_user/2" do
    test "authenticates and hydrates the local organization", %{
      conn: conn,
      user: user,
      local_session: local_session
    } do
      conn =
        conn
        |> put_session(:auth_session_token, local_session.handle)
        |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user.id == user.id
      assert conn.assigns.current_scope.organization.personal
      assert conn.assigns.auth_session.id == local_session.session.id
    end

    test "clears an invalid opaque handle", %{conn: conn} do
      conn =
        conn
        |> put_session(:auth_session_token, "invalid")
        |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope == nil
      refute get_session(conn, :auth_session_token)
    end

    test "rejects a locally revoked WorkOS session", %{
      conn: conn,
      local_session: local_session
    } do
      {:ok, _revoked} = Session.revoke(local_session.handle)

      conn =
        conn
        |> put_session(:auth_session_token, local_session.handle)
        |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope == nil
      refute get_session(conn, :auth_session_token)
    end

    test "uses the organization fixed on the server-side session", %{conn: conn, user: user} do
      organization = organization_fixture()
      organization_membership_fixture(user, organization)
      local_session = workos_session_fixture(user, org_id: organization.id)

      conn =
        conn
        |> put_session(:auth_session_token, local_session.handle)
        |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.organization.id == organization.id
      refute get_session(conn, :org_id)
    end
  end

  describe "LiveView on_mount" do
    test "assigns the verified scope and auth session", %{
      conn: conn,
      user: user,
      local_session: local_session
    } do
      session =
        conn
        |> put_session(:auth_session_token, local_session.handle)
        |> get_session()

      assert {:cont, socket} =
               UserAuth.on_mount(
                 :require_authenticated,
                 %{},
                 session,
                 %Phoenix.LiveView.Socket{}
               )

      assert socket.assigns.current_scope.user.id == user.id
      assert socket.assigns.auth_session.id == local_session.session.id
    end

    test "redirects an anonymous protected mount", %{conn: conn} do
      socket = %Phoenix.LiveView.Socket{
        endpoint: HermitscaleWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:halt, halted_socket} =
               UserAuth.on_mount(:require_authenticated, %{}, get_session(conn), socket)

      assert halted_socket.assigns.current_scope == nil
    end

    test "requires WorkOS auth_time freshness for sudo mounts", %{conn: conn, user: user} do
      stale_session =
        workos_session_fixture(user,
          authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )

      session =
        conn
        |> put_session(:auth_session_token, stale_session.handle)
        |> get_session()

      socket = %Phoenix.LiveView.Socket{
        endpoint: HermitscaleWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:halt, _socket} =
               UserAuth.on_mount(:require_sudo_mode, %{}, session, socket)
    end
  end

  describe "require_authenticated_user/2" do
    test "redirects and stores a GET return path", %{conn: conn} do
      conn =
        %{conn | path_info: ["users", "settings"], query_string: ""}
        |> assign(:current_scope, nil)
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :user_return_to) == "/users/settings"
    end

    test "continues for a verified scope", %{conn: conn, user: user} do
      scope = user_scope_fixture(user)

      conn =
        conn
        |> assign(:current_scope, scope)
        |> UserAuth.require_authenticated_user([])

      refute conn.halted
    end
  end

  describe "clear_workos_session/1" do
    test "disconnects the LiveView topic and clears all session data", %{
      conn: conn,
      local_session: local_session
    } do
      topic = Session.socket_topic(local_session.session)
      HermitscaleWeb.Endpoint.subscribe(topic)

      conn =
        conn
        |> put_session(:auth_session_token, local_session.handle)
        |> put_session(:live_socket_id, topic)
        |> UserAuth.clear_workos_session()

      refute get_session(conn, :auth_session_token)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
    end
  end
end
