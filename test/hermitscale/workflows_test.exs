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
    test "creates a graph owned by the active organization", %{scope: scope} do
      other_scope = user_scope_fixture()

      attrs =
        graph_attrs()
        |> Map.put(:org_id, other_scope.organization.id)
        |> Map.put(:created_by_user_id, other_scope.user.id)

      assert {:ok, %Graph{} = graph} = Workflows.create_graph(scope, attrs)
      assert graph.id == "wf_order_fulfillment"
      assert graph.org_id == scope.organization.id
      assert graph.created_by_user_id == scope.user.id
      assert graph.validation_issues == []
      assert graph.validated_at
    end

    test "lists only graphs owned by the active organization", %{scope: scope} do
      other_scope = organization_scope_fixture(scope.user, organization_fixture())

      assert {:ok, graph} =
               Workflows.create_graph(scope, graph_attrs(id: "wf_owned", name: "Owned"))

      assert {:ok, _other_graph} =
               Workflows.create_graph(
                 other_scope,
                 graph_attrs(id: "wf_not_owned", name: "Not owned")
               )

      assert Workflows.list_graphs(scope) == [graph]
    end

    test "gets graphs only through their owning organization", %{scope: scope} do
      other_scope = organization_scope_fixture(scope.user, organization_fixture())
      assert {:ok, graph} = Workflows.create_graph(scope, graph_attrs())

      assert Workflows.get_graph!(scope, graph.id) == graph

      assert_raise Ecto.NoResultsError, fn ->
        Workflows.get_graph!(other_scope, graph.id)
      end
    end

    test "rejects updates from another organization", %{scope: scope} do
      other_scope = organization_scope_fixture(scope.user, organization_fixture())
      assert {:ok, graph} = Workflows.create_graph(scope, graph_attrs())

      assert_raise MatchError, fn ->
        Workflows.update_graph(other_scope, graph, %{name: "stolen"})
      end
    end

    test "allows organization members to share and update graphs", %{scope: scope} do
      org = organization_fixture()
      creator_scope = organization_scope_fixture(scope.user, org)
      collaborator_scope = organization_scope_fixture(user_fixture(), org)

      assert {:ok, graph} = Workflows.create_graph(creator_scope, graph_attrs())

      assert Workflows.list_graphs(collaborator_scope) == [graph]
      assert Workflows.get_graph!(collaborator_scope, graph.id) == graph

      assert {:ok, updated_graph} =
               Workflows.update_graph(collaborator_scope, graph, %{
                 name: "Shared workflow",
                 org_id: scope.organization.id,
                 created_by_user_id: collaborator_scope.user.id
               })

      assert updated_graph.name == "Shared workflow"
      assert updated_graph.org_id == org.id
      assert updated_graph.created_by_user_id == creator_scope.user.id
    end

    test "stores WorkOS creator metadata without requiring a local user", %{scope: scope} do
      assert {:ok, graph} = Workflows.create_graph(scope, graph_attrs())
      assert graph.created_by_user_id == scope.user.id
      assert graph.org_id == scope.organization.id
      refute :organization in Graph.__schema__(:associations)
      refute :created_by_user in Graph.__schema__(:associations)
    end

    test "organization members can edit and run a shared selected account", %{scope: scope} do
      collaborator = organization_scope_fixture(user_fixture(), scope.organization)

      assert {:ok, graph} =
               Workflows.create_graph(scope, graph_attrs(definition: credential_probe_graph()))

      assert {:ok, graph} = Workflows.update_graph(collaborator, graph, %{name: "Shared"})
      assert {:ok, run} = Workflows.start_run(collaborator, graph, %{}, executor: :inline)
      assert run.initiated_by_user_id == collaborator.user.id
      assert run.execution_actor_user_id == collaborator.user.id

      assert run.account_selections == %{
               "probe" => %{"provider" => "test.credentials", "account_id" => "data_test"}
             }
    end

    test "run-only users cannot edit or substitute saved graph definitions", %{scope: scope} do
      assert {:ok, graph} =
               Workflows.create_graph(scope, graph_attrs(definition: credential_probe_graph()))

      runner = put_in(scope.membership.permissions, ["workflows:run"])
      assert {:error, :forbidden} = Workflows.create_graph(runner, graph_attrs(id: "forged"))
      assert {:error, :forbidden} = Workflows.update_graph(runner, graph, %{name: "forged"})
      supplied = %{graph | definition: valid_join_graph()}
      assert {:ok, run} = Workflows.start_run(runner, supplied, %{}, executor: :inline)
      assert run.account_selections["probe"]["account_id"] == "data_test"
    end

    test "returns a changeset with validation issues for invalid graph JSON", %{scope: scope} do
      attrs = graph_attrs(definition: valid_join_graph(%{"nodes" => []}))

      assert {:error, changeset} = Workflows.create_graph(scope, attrs)
      assert %{definition: ["is not a valid workflow graph"]} = errors_on(changeset)
      assert [_issue | _] = Ecto.Changeset.get_field(changeset, :validation_issues)
    end

    test "updates metadata without replacing the saved definition", %{scope: scope} do
      assert {:ok, graph} = Workflows.create_graph(scope, graph_attrs())
      assert {:ok, updated} = Workflows.update_graph(scope, graph, %{"name" => "Renamed"})
      assert updated.definition == graph.definition
      assert updated.name == "Renamed"
    end

    test "rejects an explicit null definition without changing the graph", %{scope: scope} do
      assert {:ok, graph} = Workflows.create_graph(scope, graph_attrs())

      assert {:error, changeset} = Workflows.update_graph(scope, graph, %{definition: nil})
      assert %{definition: ["can't be blank"]} = errors_on(changeset)
      assert Workflows.get_graph!(scope, graph.id) == graph
    end

    test "authoring cannot replace server-owned validation metadata", %{scope: scope} do
      assert {:ok, graph} = Workflows.create_graph(scope, graph_attrs())

      changeset =
        Workflows.change_graph(scope, graph, %{
          validation_issues: [%{"message" => "forged"}],
          validated_at: DateTime.add(graph.validated_at, 60, :second)
        })

      assert Ecto.Changeset.get_field(changeset, :validation_issues) == graph.validation_issues
      assert Ecto.Changeset.get_field(changeset, :validated_at) == graph.validated_at
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

    test "appends ordered events and replaces checkpoints atomically" do
      {:ok, state} = PostgresStore.init_store(repo: Repo)
      id = "run_store_sequence"

      assert {:error, :not_found} = PostgresStore.load(id, state)
      assert {:ok, 2} = PostgresStore.append(id, [:first, :second], state)
      assert {:ok, 3} = PostgresStore.append(id, [:third], state)
      assert {:ok, [:first, :second, :third]} = PostgresStore.stream(id, state)
      assert Repo.get!(Run, id).last_event_sequence == 3

      assert :ok = PostgresStore.checkpoint(id, [:checkpoint], state)
      assert {:ok, 2} = PostgresStore.append(id, [:after_checkpoint], state)
      assert {:ok, [:checkpoint, :after_checkpoint]} = PostgresStore.load(id, state)
      assert Repo.get!(Run, id).last_event_sequence == 2

      assert :ok = PostgresStore.delete(id, state)
      assert :ok = PostgresStore.delete(id, state)
      refute PostgresStore.exists?(id, state)
      assert {:error, :not_found} = PostgresStore.load(id, state)
    end
  end

  describe "start_run/4" do
    test "inline admission can leave an asynchronous component running", %{scope: scope} do
      assert {:ok, graph} =
               Workflows.create_graph(scope, graph_attrs(definition: completion_probe_graph()))

      assert {:ok, %Run{status: :running} = run} =
               Workflows.start_run(scope, graph, %{"result" => "ready"},
                 executor: :inline,
                 scheduler_policies: [
                   {{:name, ~r/^probe$/}, %{executor: Runic.Runner.Executor.Task}}
                 ],
                 run_context: %{"probe" => %{observer: self()}}
               )

      on_exit(fn -> Runic.Runner.stop(Hermitscale.WorkflowRunner, run.id, persist: false) end)
      assert_receive {:workflow_node_waiting, task}, 1_000
      assert :ok = Workflows.subscribe_run(scope, run.id)
      send(task, :release)
      assert_receive {:run_complete, id}, 1_000
      assert id == run.id
      assert Workflows.get_run!(scope, run.id).status == :complete
    end

    test "completion uses the admitted graph after an author edits the stored graph", %{
      scope: scope
    } do
      assert {:ok, graph} =
               Workflows.create_graph(scope, graph_attrs(definition: completion_probe_graph()))

      input = %{"result" => "original"}

      assert {:ok, run} =
               Workflows.start_run(scope, graph, input,
                 run_context: %{"probe" => %{observer: self()}}
               )

      on_exit(fn -> Runic.Runner.stop(Hermitscale.WorkflowRunner, run.id, persist: false) end)
      assert_receive {:workflow_node_waiting, task}, 1_000

      assert {:ok, _updated} =
               Workflows.update_graph(scope, graph, %{definition: valid_join_graph()})

      assert :ok = Workflows.subscribe_run(scope, run.id)
      send(task, :release)
      assert_receive {:run_complete, id}, 1_000
      assert id == run.id
      assert Workflows.get_run!(scope, run.id).output == %{"value" => %{"probe" => [input]}}
    end

    test "idle persistence failure remains a failed durable outcome", %{scope: scope} do
      assert {:ok, graph} = Workflows.create_graph(scope, graph_attrs())
      assert {:ok, run} = Workflows.create_run(scope, graph, %{status: :running})
      assert :ok = Workflows.subscribe_run(scope, run.id)

      # A store can return arbitrary dependency details, including secrets.
      worker = idle_worker_fixture(run, persistence: {:error, "sensitive dependency detail"})

      assert {:ok, %Run{status: :failed} = failed} = Workflows.record_run_idle(worker, [])
      assert failed.output == nil
      assert failed.error == %{"reason" => "workflow_persistence_failed"}
      assert failed.completed_at
      assert_receive {:run_failed, id}
      assert id == run.id
      refute_receive {:run_complete, _id}
    end

    test "records exhausted node failures as failed runs", %{scope: scope} do
      assert {:ok, graph} =
               Workflows.create_graph(scope, graph_attrs(definition: failing_math_graph()))

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %Run{status: :failed} = run} =
                 Workflows.start_run(scope, graph, %{}, executor: :inline)

        stored = Workflows.get_run!(scope, run.id)
        assert stored.status == :failed
        assert stored.completed_at
        assert stored.output == nil
        assert stored.error == %{"reason" => "workflow_execution_failed"}
      end)
    end

    test "resume preserves actor and account snapshots while authorizing its requester", %{
      scope: scope
    } do
      collaborator = organization_scope_fixture(user_fixture(), scope.organization)

      assert {:ok, graph} =
               Workflows.create_graph(scope, graph_attrs(definition: credential_probe_graph()))

      assert {:ok, run} = Workflows.start_run(scope, graph, %{}, executor: :inline)
      assert :ok = Runic.Runner.stop(Hermitscale.WorkflowRunner, run.id, persist: false)
      changed = graph.definition

      changed =
        put_in(changed["nodes"], [
          put_in(hd(changed["nodes"])["connection"]["account_id"], "data_other")
        ])

      assert {:ok, _graph} = Workflows.update_graph(scope, graph, %{definition: changed})
      assert {:ok, _pid} = Workflows.resume_run(collaborator, run)
      assert {:ok, workflow} = Runic.Runner.get_workflow(Hermitscale.WorkflowRunner, run.id)
      reference = Workflow.get_run_context(workflow)["probe"].credentials
      assert reference.account_id == "data_test"
      assert reference.execution_context.actor_user_id == scope.user.id
      assert :ok = Runic.Runner.stop(Hermitscale.WorkflowRunner, run.id, persist: false)
      forbidden = put_in(collaborator.membership.permissions, [])
      assert {:error, :forbidden} = Workflows.resume_run(forbidden, run)
    end

    test "credential material is absent from run output and persisted events", %{scope: scope} do
      previous = Application.get_env(:hermitscale, :google_sheets_req_options, [])

      Application.put_env(:hermitscale, :google_sheets_req_options,
        plug: fn conn ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer access_123"]
          Req.Test.json(conn, %{"values" => [["access_123"]]})
        end
      )

      on_exit(fn -> Application.put_env(:hermitscale, :google_sheets_req_options, previous) end)
      definition = credential_probe_graph()

      definition =
        put_in(definition["nodes"], [
          %{
            "id" => "read",
            "type" => "google.sheets.read_rows",
            "version" => 1,
            "params" => %{"spreadsheet_id" => "sheet"},
            "connection" => %{"provider" => "google", "account_id" => "data_google"}
          }
        ])

      assert {:ok, graph} = Workflows.create_graph(scope, graph_attrs(definition: definition))
      assert {:ok, run} = Workflows.start_run(scope, graph, %{}, executor: :inline)
      stored = Workflows.get_run!(scope, run.id)
      refute Jason.encode!(stored.output) =~ "access_123"
      {store, state} = Runic.Runner.get_store(Hermitscale.WorkflowRunner)
      assert {:ok, events} = store.stream(run.id, state)
      refute :erlang.term_to_binary(Enum.to_list(events)) =~ "access_123"
    end

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

    test "rejects a graph owned by another organization", %{scope: scope} do
      other_scope = organization_scope_fixture(scope.user, organization_fixture())
      assert {:ok, graph} = Workflows.create_graph(scope, graph_attrs())

      assert_raise MatchError, fn ->
        Workflows.start_run(other_scope, graph, %{}, executor: :inline)
      end
    end

    test "does not expose runs after switching organizations", %{scope: scope} do
      other_scope = organization_scope_fixture(scope.user, organization_fixture())
      assert {:ok, graph} = Workflows.create_graph(scope, graph_attrs())

      assert {:ok, %Run{} = run} =
               Workflows.start_run(scope, graph, %{}, executor: :inline)

      assert_raise Ecto.NoResultsError, fn ->
        Workflows.get_run!(other_scope, run.id)
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
                   "account_id" => "data_test"
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

    test "rejects persisted events after graph connections change", %{scope: scope} do
      definition = rewirable_map_reduce_graph()
      assert {:ok, graph} = Workflows.create_graph(scope, graph_attrs(definition: definition))
      assert {:ok, run} = Workflows.start_run(scope, graph, %{}, executor: :inline)
      assert :ok = Runic.Runner.stop(Hermitscale.WorkflowRunner, run.id, persist: false)

      changed =
        put_in(definition["connections"], [
          %{"from" => "b", "to" => "mapper"},
          %{"from" => "mapper", "to" => "sum"}
        ])

      assert {:ok, _graph} = Workflows.update_graph(scope, graph, %{definition: changed})

      assert {:error, :incompatible_workflow_events} =
               Workflows.resume_run(scope, run, executor: :inline)
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
