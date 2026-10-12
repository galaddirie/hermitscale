defmodule HermitscaleWeb.PageControllerTest do
  use HermitscaleWeb.ConnCase, async: true

  test "GET / renders the generated Phoenix starter page", %{conn: conn} do
    document =
      conn
      |> get(~p"/")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert Enum.count(
             LazyHTML.query(document, "a[href='https://phoenix.hexdocs.pm/overview.html']")
           ) == 1

    assert Enum.count(
             LazyHTML.query(document, "a[href='https://github.com/phoenixframework/phoenix']")
           ) == 1
  end

  test "the starter page does not process WorkOS browser cookies", %{conn: conn} do
    conn = conn |> put_req_cookie("_hermitscale_workos", "obsolete-session") |> get(~p"/")
    assert conn.status == 200
    refute Map.has_key?(conn.resp_cookies, "_hermitscale_workos")
    refute Map.has_key?(conn.assigns, :current_scope)
  end

  test "custom authentication and workspace routes are absent" do
    for {method, path} <- [
          {"GET", "/auth/sign-in"},
          {"GET", "/auth/workos/callback"},
          {"DELETE", "/users/log-out"},
          {"GET", "/workspaces"}
        ] do
      assert Phoenix.Router.route_info(HermitscaleWeb.Router, method, path, "www.example.com") ==
               :error
    end
  end
end
