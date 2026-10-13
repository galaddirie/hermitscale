defmodule HermitscaleWeb.WorkflowLiveTest do
  use HermitscaleWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import HermitscaleWeb.BrowserAuthFixtures
  alias Hermitscale.Workflows
  import Hermitscale.WorkflowEditorFixtures

  setup do
    setup_provider()
    :ok
  end

  setup %{conn: conn}, do: authenticated_conn(conn)

  test "creates, configures and connects catalog actions through the visual editor", %{
    conn: conn,
    scope: scope
  } do
    {:ok, index, _html} = live(conn, ~p"/workflows")
    assert has_element?(index, "#new-workflow-form")
    index |> form("#new-workflow-form", workflow: %{name: "Calculate a total"}) |> render_submit()
    {path, _flash} = assert_redirect(index)
    {:ok, editor, _html} = live(conn, path)
    assert has_element?(editor, "#workflow-canvas")
    assert has_element?(editor, "#nodes-start")

    editor
    |> form("#add-workflow-node-form", node: %{catalog: "math@1", id: "sum"})
    |> render_submit()

    assert has_element?(editor, "#nodes-sum")
    assert has_element?(editor, "#workflow-node-config-form")

    editor
    |> form("#workflow-node-config-form",
      node_config: %{
        params: Jason.encode!(%{operation: "add", left: 2, right: 4}),
        connection: "{}",
        policy: "{}"
      }
    )
    |> render_submit()

    editor
    |> form("#connect-workflow-nodes-form", edge: %{from: "start", to: "sum", to_input: ""})
    |> render_submit()

    assert has_element?(editor, "#workflow-edges path")
    assert has_element?(editor, "#remove-edge-start-sum-main")
    assert has_element?(editor, "#workflow-save-state", "Unsaved changes")

    editor
    |> form("#save-workflow-form", graph: %{name: "Calculate a total", status: "draft"})
    |> render_submit()

    assert has_element?(editor, "#workflow-save-state", "Saved definition")
    [graph] = Workflows.list_graphs(scope)
    assert graph.definition["connections"] == [%{"from" => "start", "to" => "sum"}]

    assert Enum.find(graph.definition["nodes"], &(&1["id"] == "sum"))["params"] == %{
             "operation" => "add",
             "left" => 2,
             "right" => 4
           }

    editor |> element("#nodes-sum") |> render_click()
    editor |> element("#delete-workflow-node") |> render_click()
    refute has_element?(editor, "#nodes-sum")
    refute has_element?(editor, "#workflow-edges path")
  end

  test "a saved removed action can be inspected and deleted before saving", %{
    conn: conn,
    scope: scope
  } do
    graph = workflow_fixture(scope)

    removed = %{
      "id" => "retired",
      "type" => "support.investigate",
      "version" => 1,
      "params" => %{}
    }

    definition = Map.update!(graph.definition, "nodes", &(&1 ++ [removed]))
    graph |> Ecto.Changeset.change(definition: definition) |> Hermitscale.Repo.update!()

    {:ok, editor, _html} = live(conn, ~p"/workflows/#{graph.id}")
    editor |> element("#nodes-retired") |> render_click()
    assert has_element?(editor, "#workflow-node-config-form")
    editor |> element("#delete-workflow-node") |> render_click()
    refute has_element?(editor, "#nodes-retired")

    editor
    |> form("#save-workflow-form", graph: %{name: graph.name, status: "draft"})
    |> render_submit()

    assert Workflows.get_graph!(scope, graph.id).definition == graph.definition
  end

  test "invalid parameter JSON and cycles remain visible and cannot overwrite a saved definition",
       %{conn: conn, scope: scope} do
    graph = workflow_fixture(scope)
    {:ok, editor, _html} = live(conn, ~p"/workflows/#{graph.id}")
    editor |> element("#nodes-start") |> render_click()

    editor
    |> form("#workflow-node-config-form",
      node_config: %{params: "invalid JSON", connection: "{}", policy: "{}"}
    )
    |> render_submit()

    assert Workflows.get_graph!(scope, graph.id).definition == graph.definition

    editor
    |> form("#add-workflow-node-form", node: %{catalog: "debug@1", id: "second"})
    |> render_submit()

    editor
    |> form("#connect-workflow-nodes-form", edge: %{from: "start", to: "second"})
    |> render_submit()

    editor
    |> form("#connect-workflow-nodes-form", edge: %{from: "second", to: "start"})
    |> render_submit()

    assert has_element?(editor, "#issues-0")

    editor
    |> form("#save-workflow-form", graph: %{name: graph.name, status: "draft"})
    |> render_submit()

    assert Workflows.get_graph!(scope, graph.id).definition == graph.definition
    assert has_element?(editor, "#workflow-save-state", "Unsaved changes")
  end

  test "starts a saved workflow and displays recorded completion", %{conn: conn, scope: scope} do
    graph = workflow_fixture(scope)
    {:ok, editor, _html} = live(conn, ~p"/workflows/#{graph.id}")

    editor
    |> form("#workflow-run-form",
      run_input: %{input: Jason.encode!(%{"message" => "Process this input"})}
    )
    |> render_submit()

    assert has_element?(editor, "#workflow-run-detail")

    [run] = Workflows.list_runs(scope, graph.id)
    :ok = Workflows.subscribe_run(scope, run.id)

    on_exit(fn -> Runic.Runner.stop(Hermitscale.WorkflowRunner, run.id, persist: false) end)

    if Workflows.get_run!(scope, run.id).status != :complete do
      assert_receive {:run_complete, id}, 1_000
      assert id == run.id
    end

    editor |> element("#refresh-workflow-run") |> render_click()
    assert has_element?(editor, "#workflow-run-status", "complete")
    assert has_element?(editor, "#workflow-run-output")
    run = Workflows.get_run!(scope, run.id)
    assert run.status == :complete

    assert_patch(editor, ~p"/workflows/#{graph.id}?run_id=#{run.id}")
    {:ok, reopened, _html} = live(conn, ~p"/workflows/#{graph.id}?run_id=#{run.id}")
    assert has_element?(reopened, "#workflow-run-status", "complete")
    assert has_element?(reopened, "#workflow-runs [data-run-id='#{run.id}']")
    assert has_element?(reopened, "#workflow-run-output")

    other = workflow_fixture(scope)
    {:ok, unrelated, _html} = live(conn, ~p"/workflows/#{other.id}?run_id=#{run.id}")
    refute has_element?(unrelated, "#workflow-run-detail")
    refute has_element?(unrelated, "#workflow-runs [data-run-id='#{run.id}']")
  end

  test "anonymous and foreign organization workflows are denied", %{conn: conn, scope: scope} do
    assert {:error, {:redirect, %{to: "/auth/login"}}} = live(build_conn(), ~p"/workflows")
    graph = workflow_fixture(scope)
    other = Hermitscale.AccountsFixtures.organization_scope_fixture()
    assert Workflows.list_graphs(other) == []

    assert {:error, {:live_redirect, %{to: "/workflows"}}} =
             live(conn, ~p"/workflows/unknown_workflow")

    assert {:ok, _editor, _html} = live(conn, ~p"/workflows/#{graph.id}")
  end
end
