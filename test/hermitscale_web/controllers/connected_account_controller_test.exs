defmodule HermitscaleWeb.ConnectedAccountControllerTest do
  use HermitscaleWeb.ConnCase, async: false

  alias Hermitscale.Integrations.{ConnectedAccount, ConnectedAccounts}
  alias Hermitscale.Repo
  alias Hermitscale.WorkOSTest.Client

  import Hermitscale.AccountsFixtures

  setup do
    start_supervised!({Client, %{}})
    previous = Application.get_env(:hermitscale, ConnectedAccounts, [])
    Application.put_env(:hermitscale, ConnectedAccounts, Keyword.put(previous, :client, Client))

    on_exit(fn -> Application.put_env(:hermitscale, ConnectedAccounts, previous) end)
  end

  test "starts a Pipes redirect only inside the authenticated tenant", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)

    conn =
      post(
        conn,
        ~p"/users/settings/connected-accounts/google/connect",
        %{"connection" => %{"sharing_mode" => "private"}}
      )

    assert redirected_to(conn) == "https://api.workos.com/pipes/authorize"

    assert [
             {:authorize_connection, ["google", workos_user_id, nil, return_to]}
           ] = Client.calls()

    assert workos_user_id == user.workos_user_id
    assert URI.parse(return_to).path == "/users/settings/connected-accounts"
  end

  test "updates and revokes a local organization sharing grant", %{conn: conn} do
    user = user_fixture()

    organization =
      organization_fixture(
        workos_organization_id: "org_sharing_controller",
        provisioning_state: :ready,
        workos_updated_at: DateTime.utc_now(:microsecond)
      )

    organization_membership_fixture(user, organization, role: :owner)

    account =
      connected_account_fixture(user, organization, sharing_mode: :private)

    conn = log_in_user(conn, user, org_id: organization.id)

    conn =
      patch(
        conn,
        ~p"/users/settings/connected-accounts/google/sharing",
        %{"connection" => %{"sharing_mode" => "organization"}}
      )

    assert redirected_to(conn) == "/users/settings/connected-accounts"
    assert Repo.get!(ConnectedAccount, account.id).sharing_mode == :organization

    conn =
      conn
      |> recycle()
      |> log_in_user(user, org_id: organization.id)
      |> patch(
        ~p"/users/settings/connected-accounts/google/sharing",
        %{"connection" => %{"sharing_mode" => "private"}}
      )

    assert redirected_to(conn) == "/users/settings/connected-accounts"
    assert Repo.get!(ConnectedAccount, account.id).sharing_mode == :private
  end

  test "disconnect blocks local use and deletes the WorkOS mapping", %{conn: conn} do
    user = user_fixture()
    scope = user_scope_fixture(user)
    account = connected_account_fixture(user, scope.organization)
    conn = log_in_user(conn, user)

    conn =
      delete(
        conn,
        ~p"/users/settings/connected-accounts/google"
      )

    assert redirected_to(conn) == "/users/settings/connected-accounts"
    assert Repo.get!(ConnectedAccount, account.id).state == :disconnected

    assert [
             {:delete_connected_account, ["google", workos_user_id, nil]}
           ] = Client.calls()

    assert workos_user_id == user.workos_user_id
  end

  test "requires authentication for every mutation", %{conn: conn} do
    conn =
      post(
        conn,
        ~p"/users/settings/connected-accounts/google/connect",
        %{"connection" => %{"sharing_mode" => "private"}}
      )

    assert redirected_to(conn) == "/users/log-in"
    assert Client.calls() == []
  end
end
