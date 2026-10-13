defmodule HermitscaleWeb.PageControllerTest do
  use HermitscaleWeb.ConnCase, async: true

  test "GET / offers browser sign-in and states execution availability", %{conn: conn} do
    document =
      conn
      |> get(~p"/")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query(document, "#home-sign-in[href='/auth/login']")) == 1

    assert Enum.count(LazyHTML.query(document, "#home-runtime-status")) == 1
  end

  test "obsolete browser cookies grant no authority", %{conn: conn} do
    conn = conn |> put_req_cookie("_hermitscale_workos", "obsolete-session") |> get(~p"/")
    assert conn.status == 200
    refute Map.has_key?(conn.resp_cookies, "_hermitscale_workos")
    assert conn.assigns.current_scope == nil
  end

  test "obsolete authentication and workspace routes remain absent" do
    for {method, path} <- [
          {"GET", "/auth/sign-in"},
          {"GET", "/auth/callback"},
          {"DELETE", "/users/log-out"},
          {"GET", "/workspaces"}
        ] do
      assert Phoenix.Router.route_info(HermitscaleWeb.Router, method, path, "www.example.com") ==
               :error
    end
  end
end
