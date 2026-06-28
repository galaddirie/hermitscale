defmodule Hermitscale.WorkflowsTest do
  use Hermitscale.DataCase

  import Hermitscale.WorkflowsFixtures

  alias Hermitscale.Workflows
  alias Hermitscale.Workflows.{Graph, PostgresStore, Run}
  alias Runic.Workflow

  describe "create_graph/1" do
    test "stores a valid workflow graph" do
      assert {:ok, %Graph{} = graph} = Workflows.create_graph(graph_attrs())
      assert graph.id == "wf_order_fulfillment"
      assert graph.validation_issues == []
      assert graph.validated_at
    end

    test "returns a changeset with validation issues for invalid graph JSON" do
      attrs = graph_attrs(definition: valid_join_graph(%{"nodes" => []}))

      assert {:error, changeset} = Workflows.create_graph(attrs)
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

  describe "start_run/3" do
    test "starts a graph through the supervised Runic runner" do
      assert {:ok, graph} = Workflows.create_graph(graph_attrs(id: "wf_runner_test"))
      input = %{"sku" => "ABC-123"}

      assert {:ok, %Run{} = run} = Workflows.start_run(graph, input, executor: :inline)
      assert {:ok, results} = Runic.Runner.get_results(Hermitscale.WorkflowRunner, run.id)

      assert Enum.any?(results, &match?(%{left: ^input, right: ^input}, &1))

      run = Workflows.get_run!(run.id)
      assert run.status == :complete
      assert run.completed_at
    end

    test "resolves credential references into run context before execution" do
      attrs =
        graph_attrs(
          id: "wf_runner_credentials_test",
          name: "runner_credentials_test",
          definition: credential_probe_graph()
        )

      assert {:ok, graph} = Workflows.create_graph(attrs)

      assert {:ok, %Run{} = run} =
               Workflows.start_run(graph, %{"input" => true}, executor: :inline)

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
  end
end
