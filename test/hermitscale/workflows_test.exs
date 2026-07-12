defmodule Hermitscale.WorkflowsTest do
  use Hermitscale.DataCase

  import Hermitscale.AccountsFixtures
  import Hermitscale.WorkflowsFixtures

  alias Hermitscale.Workflows
  alias Hermitscale.Workflows.{Graph, PostgresStore, Run}
  alias Runic.Workflow

  setup do
    %{scope: user_scope_fixture()}
  end

  describe "graphs" do
    test "creates a graph owned by the current scope", %{scope: scope} do
      attrs = Map.put(graph_attrs(), :user_id, user_scope_fixture().user.id)

      assert {:ok, %Graph{} = graph} = Workflows.create_graph(scope, attrs)
      assert graph.id == "wf_order_fulfillment"
      assert graph.user_id == scope.user.id
      assert graph.validation_issues == []
      assert graph.validated_at
    end

    test "lists only graphs owned by the current scope", %{scope: scope} do
      other_scope = user_scope_fixture()

      assert {:ok, graph} =
               Workflows.create_graph(scope, graph_attrs(id: "wf_owned", name: "Owned"))

      assert {:ok, _other_graph} =
               Workflows.create_graph(
                 other_scope,
                 graph_attrs(id: "wf_not_owned", name: "Not owned")
               )

      assert Workflows.list_graphs(scope) == [graph]
    end

    test "gets graphs only through their owning scope", %{scope: scope} do
      other_scope = user_scope_fixture()
      assert {:ok, graph} = Workflows.create_graph(scope, graph_attrs())

      assert Workflows.get_graph!(scope, graph.id) == graph

      assert_raise Ecto.NoResultsError, fn ->
        Workflows.get_graph!(other_scope, graph.id)
      end
    end

    test "rejects updates from another scope", %{scope: scope} do
      other_scope = user_scope_fixture()
      assert {:ok, graph} = Workflows.create_graph(scope, graph_attrs())

      assert_raise MatchError, fn ->
        Workflows.update_graph(other_scope, graph, %{name: "stolen"})
      end
    end

    test "returns a changeset with validation issues for invalid graph JSON", %{scope: scope} do
      attrs = graph_attrs(definition: valid_join_graph(%{"nodes" => []}))

      assert {:error, changeset} = Workflows.create_graph(scope, attrs)
      assert %{definition: ["is not a valid workflow graph"]} = errors_on(changeset)
      assert [_issue | _] = Ecto.Changeset.get_field(changeset, :validation_issues)
    end
  end

  describe "PostgresStore" do
    test "appends and streams Runic events" do
      {:ok, state} = PostgresStore.init_store(repo: Repo)
      workflow = Workflow.new("store_test")
      events = Workflow.build_log(workflow)

      assert {:ok, 0} = PostgresStore.append("run_store_test", events, state)
      assert {:ok, []} = PostgresStore.stream("run_store_test", state)
      assert PostgresStore.exists?("run_store_test", state)
    end
  end

  describe "start_run/4" do
    test "starts a graph through the supervised Runic runner", %{scope: scope} do
      assert {:ok, graph} =
               Workflows.create_graph(scope, graph_attrs(id: "wf_runner_test"))

      input = %{"sku" => "ABC-123"}

      assert {:ok, %Run{} = run} =
               Workflows.start_run(scope, graph, input, executor: :inline)

      assert {:ok, results} = Runic.Runner.get_results(Hermitscale.WorkflowRunner, run.id)

      assert Enum.any?(
               results,
               &match?(%{merged: [^input, ^input]}, &1)
             )

      run = Workflows.get_run!(scope, run.id)
      assert run.status == :complete
      assert run.completed_at
    end

    test "rejects a graph owned by another scope", %{scope: scope} do
      other_scope = user_scope_fixture()
      assert {:ok, graph} = Workflows.create_graph(scope, graph_attrs())

      assert_raise MatchError, fn ->
        Workflows.start_run(other_scope, graph, %{}, executor: :inline)
      end
    end

    test "resolves credential references into run context before execution", %{scope: scope} do
      attrs =
        graph_attrs(
          id: "wf_runner_credentials_test",
          name: "runner_credentials_test",
          definition: credential_probe_graph()
        )

      assert {:ok, graph} = Workflows.create_graph(scope, attrs)

      assert {:ok, %Run{} = run} =
               Workflows.start_run(scope, graph, %{"input" => true}, executor: :inline)

      assert {:ok, results} = Runic.Runner.get_results(Hermitscale.WorkflowRunner, run.id)

      assert Enum.any?(
               results,
               &match?(
                 %{
                   "input" => true,
                   "access_token" => "token:cred_default",
                   "scopes" => ["scope:a"]
                 },
                 &1
               )
             )
    end

    test "persists only the terminal node's output, keyed by node id", %{scope: scope} do
      attrs =
        graph_attrs(
          id: "wf_runner_output_test",
          name: "runner_output_test",
          definition: map_reduce_graph()
        )

      assert {:ok, graph} = Workflows.create_graph(scope, attrs)
      input = [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}]

      assert {:ok, %Run{} = run} =
               Workflows.start_run(scope, graph, input, executor: :inline)

      run = Workflows.get_run!(scope, run.id)
      assert run.status == :complete
      # Terminal node "summer" reduces 10 + 20 + 30; intermediate facts and map
      # fan-out plumbing are excluded from the persisted result.
      assert run.output == %{"value" => %{"summer" => [60]}}
    end

    test "resumes from persisted events using the stored graph definition", %{scope: scope} do
      definition = map_reduce_graph()

      attrs =
        graph_attrs(
          id: "wf_runner_resume_region_test",
          name: "runner_resume_region_test",
          definition: definition
        )

      assert {:ok, graph} = Workflows.create_graph(scope, attrs)
      input = [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}]

      assert {:ok, %Run{} = run} =
               Workflows.start_run(scope, graph, input, executor: :inline)

      assert :ok = Runic.Runner.stop(Hermitscale.WorkflowRunner, run.id, persist: false)

      assert {:ok, _pid} = Workflows.resume_run(scope, run, executor: :inline)
      assert {:ok, results} = Runic.Runner.get_results(Hermitscale.WorkflowRunner, run.id)

      assert 60 in results
    end
  end
end
