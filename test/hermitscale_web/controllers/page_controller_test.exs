defmodule HermitscaleWeb.PageControllerTest do
  use HermitscaleWeb.ConnCase

  import Hermitscale.AccountsFixtures
  import Hermitscale.WorkflowsFixtures

  alias Hermitscale.Workflows

  test "GET / redirects guests to log in", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/users/log-in"
  end

  describe "GET / for an authenticated user" do
    setup :register_and_log_in_user

    test "renders only workflows in the current scope", %{conn: conn, scope: scope} do
      other_scope = user_scope_fixture()

      assert {:ok, graph} =
               Workflows.create_graph(scope, graph_attrs(id: "wf_dashboard", name: "Dashboard"))

      assert {:ok, other_graph} =
               Workflows.create_graph(
                 other_scope,
                 graph_attrs(id: "wf_private", name: "Private")
               )

      document =
        conn
        |> get(~p"/")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert Enum.count(LazyHTML.query(document, "#workflow-dashboard")) == 1
      assert Enum.count(LazyHTML.query(document, "#workflow-#{graph.id}")) == 1
      assert Enum.empty?(LazyHTML.query(document, "#workflow-#{other_graph.id}"))
    end
  end
end
