defmodule HermitscaleWeb.UserLive.LoginTest do
  use HermitscaleWeb.ConnCase, async: true

  import Hermitscale.AccountsFixtures
  import Phoenix.LiveViewTest

  describe "GET /users/log-in" do
    test "renders the single AuthKit entry point", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(view, "#authkit-sign-in")
      assert has_element?(view, "#authkit-sign-in-button[href='/auth/sign-in']")
      refute has_element?(view, "#login_form_magic")
      refute has_element?(view, "#login_form_password")
    end

    test "preserves a local reauthentication return path", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/users/log-in?return_to=/users/settings&max_age=600")

      assert has_element?(
               view,
               "#authkit-sign-in-button[href='/auth/sign-in?max_age=600&return_to=%2Fusers%2Fsettings']"
             )
    end

    test "renders the reauthentication state for a current WorkOS session", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(view, "#authkit-sign-in")
      assert has_element?(view, "#current-user-email")
    end
  end
end
