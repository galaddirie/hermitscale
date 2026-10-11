defmodule HermitscaleWeb.ConnectedAccountsLiveTest do
  use HermitscaleWeb.ConnCase, async: false

  alias Hermitscale.Integrations.ConnectedAccounts
  alias Hermitscale.WorkOSTest.Client

  import Hermitscale.AccountsFixtures
  import Phoenix.LiveViewTest

  setup do
    start_supervised!({Client, %{}})
    previous = Application.get_env(:hermitscale, ConnectedAccounts, [])
    Application.put_env(:hermitscale, ConnectedAccounts, Keyword.put(previous, :client, Client))

    on_exit(fn -> Application.put_env(:hermitscale, ConnectedAccounts, previous) end)
  end

  test "renders stable provider and connect controls for a personal organization", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)

    {:ok, view, _html} = live(conn, ~p"/users/settings/connected-accounts")

    assert has_element?(view, "#connected-accounts-page")
    assert has_element?(view, "#connected-account-providers[phx-update='stream']")
    assert has_element?(view, "#connected-provider-google")
    assert has_element?(view, "#connect-provider-google")
    assert has_element?(view, "#connect-provider-button-google")
    assert has_element?(view, "#provider-revocation-note")
    refute has_element?(view, "#sharing-provider-google")
  end

  test "renders sharing, impact, and disconnect controls for a shared connection", %{conn: conn} do
    user = user_fixture()

    organization =
      organization_fixture(
        workos_organization_id: "org_shared_ui",
        provisioning_state: :ready,
        workos_updated_at: DateTime.utc_now(:microsecond)
      )

    organization_membership_fixture(user, organization, role: :owner)
    connected_account_fixture(user, organization, sharing_mode: :organization)
    conn = log_in_user(conn, user, org_id: organization.id)

    {:ok, view, _html} = live(conn, ~p"/users/settings/connected-accounts")

    assert has_element?(view, "#disconnect-provider-google")
    assert has_element?(view, "#sharing-provider-google")
    assert has_element?(view, "#save-sharing-provider-google")
    assert has_element?(view, "#connection-impact-warning-google")
    refute has_element?(view, "#connect-provider-google")
  end

  test "redirects an anonymous request", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(conn, ~p"/users/settings/connected-accounts")
  end
end
