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

    test "renders workflows shared by the active organization", %{conn: conn, user: user} do
      org = organization_fixture(name: "Shared Operations")
      _scope = organization_scope_fixture(user, org)
      collaborator_scope = organization_scope_fixture(user_fixture(), org)
      other_scope = organization_scope_fixture(user, organization_fixture())

      assert {:ok, graph} =
               Workflows.create_graph(
                 collaborator_scope,
                 graph_attrs(id: "wf_dashboard", name: "Dashboard")
               )

      assert {:ok, other_graph} =
               Workflows.create_graph(
                 other_scope,
                 graph_attrs(id: "wf_private", name: "Private")
               )

      document =
        conn
        |> put_session(:org_id, org.id)
        |> get(~p"/")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert Enum.count(LazyHTML.query(document, "#workflow-dashboard")) == 1
      assert Enum.count(LazyHTML.query(document, "#current-organization-name")) == 1
      assert Enum.count(LazyHTML.query(document, "#workflow-#{graph.id}")) == 1
      assert Enum.empty?(LazyHTML.query(document, "#workflow-#{other_graph.id}"))
    end
  end
end
