defmodule HermitscaleWeb.UserLive.SettingsTest do
  use HermitscaleWeb.ConnCase, async: true

  import Hermitscale.AccountsFixtures
  import Phoenix.LiveViewTest

  describe "GET /users/settings" do
    test "renders the WorkOS profile and connected-account entry point", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      assert has_element?(view, "#account-settings")
      assert has_element?(view, "#workos-profile")

      assert has_element?(
               view,
               "#manage-connected-accounts[href='/users/settings/connected-accounts']"
             )

      assert has_element?(view, "#account-danger-zone")
      refute has_element?(view, "#email_form")
      refute has_element?(view, "#password_form")
    end

    test "shows organizations with stable switch controls", %{conn: conn} do
      user = user_fixture()
      organization = organization_fixture()
      organization_membership_fixture(user, organization)

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      assert has_element?(view, "#settings-organizations")

      assert has_element?(
               view,
               "#switch-organization-#{organization.id}[href='/organizations/#{organization.id}/switch']"
             )
    end

    test "redirects an anonymous request", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/users/settings")
    end
  end
end
