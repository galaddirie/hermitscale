defmodule HermitscaleWeb.UserAuthTest do
  use HermitscaleWeb.ConnCase, async: false

  alias Hermitscale.Auth
  alias Hermitscale.AuthTest.{Fixtures, Provider}
  alias HermitscaleWeb.UserAuth
  import HermitscaleWeb.BrowserAuthFixtures

  setup do
    setup_provider()
  end

  test "requires authentication for HTTP access", %{conn: conn} do
    response = get(conn, ~p"/agents")
    assert redirected_to(response) == ~p"/auth/login"
  end

  test "assigns a current scope after revalidating active membership", %{conn: conn} do
    %{conn: conn} = authenticated_conn(conn)
    conn = UserAuth.fetch_current_scope_for_user(conn, [])
    assert conn.assigns.current_scope.user.email == "owner@example.test"
    assert conn.assigns.current_scope.membership.status == "active"
    assert {:list_memberships, ["person:owner", "tenant:team"]} in Provider.calls()
  end

  test "rejects a revoked membership on LiveView reconnect", %{conn: conn} do
    %{authentication: authentication} = authenticated_conn(conn)
    assert :ok = Auth.remove_membership(Fixtures.owner_membership_id(Provider))

    assert {:halt, socket} =
             UserAuth.on_mount(
               :require_authenticated,
               %{},
               %{"sealed_session" => authentication.sealed_session},
               socket()
             )

    assert socket.assigns.current_scope == nil
    assert {:redirect, %{to: "/auth/login"}} = socket.redirected
  end

  test "rejects anonymous LiveView mounts" do
    assert {:halt, socket} = UserAuth.on_mount(:require_authenticated, %{}, %{}, socket())
    assert {:redirect, %{to: "/auth/login"}} = socket.redirected
  end

  test "persists a refreshed provider session through a cookie-bound HTTP handoff", %{conn: conn} do
    %{conn: conn, authentication: authentication} = authenticated_conn(conn)
    {:ok, refreshed} = Auth.switch_organization(authentication.sealed_session, "tenant:team")
    Provider.put_response(:authenticate, {:ok, refreshed})
    conversation_id = Ecto.UUID.generate()

    assert {:halt, socket} =
             UserAuth.on_mount(
               :require_authenticated,
               %{"id" => conversation_id},
               %{"sealed_session" => authentication.sealed_session},
               socket()
             )

    {:redirect, %{to: path}} = socket.redirected
    assert String.starts_with?(path, "/auth/session-refresh/")
    response = get(conn, path)
    assert redirected_to(response) == ~p"/agents/#{conversation_id}"
    assert get_session(response, :sealed_session) == refreshed.sealed_session
    refute path =~ refreshed.sealed_session
  end

  test "keeps the browser cookie when the auth provider is temporarily unavailable", %{conn: conn} do
    %{conn: conn, authentication: authentication} = authenticated_conn(conn)
    Provider.put_response(:authenticate, {:error, :unavailable})
    conn = UserAuth.fetch_current_scope_for_user(conn, [])
    assert conn.assigns.current_scope == nil
    assert get_session(conn, :sealed_session) == authentication.sealed_session
  end

  test "a rotated session returns to the requested app, review or workflow", %{conn: conn} do
    %{conn: conn, authentication: authentication} = authenticated_conn(conn)
    {:ok, refreshed} = Auth.switch_organization(authentication.sealed_session, "tenant:team")
    Provider.put_response(:authenticate, {:ok, refreshed})
    id = Ecto.UUID.generate()
    deployment_id = Ecto.UUID.generate()

    for {view, action, params, expected} <- [
          {HermitscaleWeb.ReviewsLive, :show, %{"id" => id}, "/reviews/" <> id},
          {HermitscaleWeb.AppLive, :build, %{"id" => id}, "/apps/" <> id <> "/build"},
          {HermitscaleWeb.AppLive, :deployment, %{"id" => id, "deployment_id" => deployment_id},
           "/apps/" <> id <> "/deployments/" <> deployment_id},
          {HermitscaleWeb.WorkflowLive, :show, %{"id" => "wf:stored_1"}, "/workflows/wf:stored_1"}
        ] do
      mounted = %{
        socket()
        | view: view,
          assigns: %{__changed__: %{}, flash: %{}, live_action: action}
      }

      assert {:halt, result} =
               UserAuth.on_mount(
                 :require_authenticated,
                 params,
                 %{"sealed_session" => authentication.sealed_session},
                 mounted
               )

      {:redirect, %{to: path}} = result.redirected
      response = get(conn, path)
      assert redirected_to(response) == expected
    end
  end

  defp socket do
    %Phoenix.LiveView.Socket{
      endpoint: HermitscaleWeb.Endpoint,
      assigns: %{__changed__: %{}, flash: %{}},
      private: %{live_temp: %{}}
    }
  end
end
