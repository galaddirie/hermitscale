defmodule HermitscaleWeb.PageControllerTest do
  use HermitscaleWeb.ConnCase, async: true

  test "GET / presents a public Phoenix starting page", %{conn: conn} do
    document =
      conn
      |> get(~p"/")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query(document, "#welcome")) == 1
    assert Enum.count(LazyHTML.query(document, "#log-in-link[href='/auth/sign-in']")) == 1
    assert Enum.empty?(LazyHTML.query(document, "#workflow-dashboard"))
  end
end
