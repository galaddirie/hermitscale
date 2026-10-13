defmodule Hermitscale.Workflows.ExternalOperationsTest do
  use Hermitscale.DataCase, async: false
  use Oban.Testing, repo: Hermitscale.Repo
  import Hermitscale.WorkflowExternalFixtures
  import Hermitscale.WorkflowsFixtures, only: [graph_attrs: 1]
  import Hermitscale.IntegrationsFixtures
  alias Hermitscale.{Auth, AuthTest.Provider, Workflows}

  alias Hermitscale.Workflows.{
    Compiler,
    Engine,
    ExternalOperations,
    ExternalOperationWorker,
    PostgresStore,
    Replay
  }

  alias Hermitscale.WorkOSTest.Client, as: Pipes

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    configure(Auth, provider: Provider)
    configure(ExternalOperations, adapter: Hermitscale.WorkflowExternalTest.Adapter)

    for client <- [Hermitscale.Integrations.GitHub.Client, Hermitscale.Integrations.Linear.Client],
        do: configure(client, req_options: [plug: {Req.Test, __MODULE__}])

    start_supervised!({Provider, %{}})
    start_supervised!({Pipes, %{}})
    {:ok, authentication} = Auth.sign_in("team-code")
    scope = authentication.current_scope

    Pipes.put_response(
      :list_org_providers,
      {:ok,
       %{
         "data" =>
           for(
             provider <- ~w(github linear),
             do: %{
               "slug" => provider,
               "connected_accounts" => [account_fixture(provider, scope.organization.id)]
             }
           )
       }}
    )

    Pipes.put_response(:vend_credentials, fn provider, _user, _org, _id ->
      {:ok,
       %{
         auth_method: "oauth",
         value: "provider-secret",
         scopes: scopes_fixture(provider),
         missing_scopes: []
       }}
    end)

    %{scope: scope}
  end

  test "coding waits durably without a successful output and survives replay", %{scope: scope} do
    {:ok, graph} = Workflows.create_graph(scope, graph_attrs(definition: coding_graph()))

    assert {:ok, run} =
             Workflows.start_run(scope, graph, %{"ticket" => "ENG-7"}, executor: :inline)

    assert run.status == :running
    assert [operation] = ExternalOperations.list(scope, run.id)
    assert operation.status == :admitted
    assert operation.definition_identity != ""
    assert Engine.productions(restore(run), "coding") == []

    assert {:error, :waiting_for_external_operations} =
             Workflows.mark_run_complete(run.id, restore(run))

    assert {:snooze, 5} = perform_job(ExternalOperationWorker, %{operation_id: operation.id})
    assert_receive {:external_dispatch, "agents.codex.run", operation_id, request}
    assert operation_id == operation.id
    assert request["instructions"] == "Fix ENG-7 and verify the changes"
    assert {:ok, resumed} = Workflows.resume_run(scope, run)
    assert resumed.status == :running
    assert [waiting] = ExternalOperations.list(scope, run.id)
    assert waiting.id == operation.id
    assert waiting.status == :waiting
    assert {:snooze, 5} = perform_job(ExternalOperationWorker, %{operation_id: operation.id})
    refute_receive {:external_dispatch, _, _, _}
  end

  test "coding to verified branch to GitHub PR to Linear notification finishes once", %{
    scope: scope
  } do
    {:ok, graph} =
      Workflows.create_graph(scope, graph_attrs(definition: coding_publication_graph()))

    {:ok, run} = Workflows.start_run(scope, graph, %{"ticket" => "ENG-7"}, executor: :inline)
    [coding] = ExternalOperations.list(scope, run.id)
    assert {:ok, _coding} = ExternalOperations.accept_terminal(coding.id, {:ok, coding_result()})
    assert {:ok, :advanced} = perform_job(ExternalOperationWorker, %{run_id: run.id})
    publish = operation(scope, run, "publish")
    assert publish.request["manifest"] == ["lib/fix.ex"]
    assert publish.request["session_id"] != ""

    assert {:ok, _publication} =
             ExternalOperations.accept_terminal(publish.id, {:ok, publication_result()})

    assert {:ok, :advanced} = perform_job(ExternalOperationWorker, %{run_id: run.id})
    pull = operation(scope, run, "pull")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/acme/backend/pulls"
      Req.Test.json(conn, [])
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/acme/backend/git/ref/heads/fix%2FENG-7"
      Req.Test.json(conn, %{"object" => %{"sha" => String.duplicate("b", 40)}})
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      attrs = Jason.decode!(body)
      assert attrs["head"] == "fix/ENG-7"
      assert attrs["body"] =~ "hermitscale-delivery:"

      Req.Test.json(
        conn,
        Map.merge(attrs, %{
          "id" => 1,
          "number" => 7,
          "html_url" => "https://github.com/acme/backend/pull/7",
          "head" => %{"sha" => String.duplicate("b", 40)}
        })
      )
    end)

    assert {:ok, :complete} = perform_job(ExternalOperationWorker, %{operation_id: pull.id})
    assert {:ok, :advanced} = perform_job(ExternalOperationWorker, %{run_id: run.id})
    notification = operation(scope, run, "notify")
    assert notification.request["body"] == "Ready: https://github.com/acme/backend/pull/7"

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{"comments" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}}
        }
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      attrs = Jason.decode!(body)
      assert attrs["variables"]["input"]["body"] =~ "hermitscale-delivery:"

      Req.Test.json(conn, %{
        "data" => %{
          "commentCreate" => %{
            "success" => true,
            "comment" => %{"id" => "comment_7", "body" => attrs["variables"]["input"]["body"]}
          }
        }
      })
    end)

    assert {:ok, :complete} =
             perform_job(ExternalOperationWorker, %{operation_id: notification.id})

    assert {:ok, :advanced} = perform_job(ExternalOperationWorker, %{run_id: run.id})
    complete = Workflows.get_run!(scope, run.id)
    assert complete.status == :complete
    assert complete.output["value"]["notify"] |> length() == 1
    assert {:ok, _run} = Workflows.resume_run(scope, complete)

    assert {:ok, :complete} =
             perform_job(ExternalOperationWorker, %{operation_id: notification.id})

    workflow = restore(complete)

    for id <- ~w(coding publish pull notify),
        do: assert(length(Engine.productions(workflow, id)) == 1)

    assert Enum.all?(ExternalOperations.list(scope, run.id), &(&1.status == :consumed))
  end

  test "duplicate completion and restart accept one native occurrence", %{scope: scope} do
    {:ok, graph} = Workflows.create_graph(scope, graph_attrs(definition: coding_graph()))
    {:ok, run} = Workflows.start_run(scope, graph, nil, executor: :inline)
    [operation] = ExternalOperations.list(scope, run.id)
    result = coding_result()
    assert {:ok, terminal} = ExternalOperations.accept_terminal(operation.id, {:ok, result})
    assert terminal.status == :terminal
    assert_enqueued(worker: ExternalOperationWorker, args: %{run_id: run.id})
    assert {:ok, same} = ExternalOperations.accept_terminal(operation.id, {:ok, result})
    assert same.id == terminal.id

    assert {:error, :terminal_outcome_conflict} =
             ExternalOperations.accept_terminal(operation.id, {:ok, %{"different" => true}})

    assert {:ok, completed} = Workflows.resume_run(scope, run)
    assert completed.status == :complete
    assert {:ok, consumed} = ExternalOperations.accept_terminal(operation.id, {:ok, result})
    assert consumed.status == :consumed
    assert {:ok, _same} = Workflows.resume_run(scope, completed)
    assert Engine.productions(restore(completed), "coding") == [result]
  end

  test "identical mapped input values remain separate external occurrences", %{scope: scope} do
    {:ok, graph} = Workflows.create_graph(scope, graph_attrs(definition: mapped_coding_graph()))
    {:ok, run} = Workflows.start_run(scope, graph, [1, 1], executor: :inline)
    operations = ExternalOperations.list(scope, run.id)
    assert length(operations) == 2
    assert length(Enum.uniq_by(operations, & &1.activation_identity)) == 2
    assert length(Enum.uniq_by(operations, & &1.input_identity)) == 2
    assert Enum.map(operations, &hd(&1.lineage["ancestry"])["index"]) |> Enum.sort() == [0, 1]
    result = %{"summary" => "same verified result"}

    for operation <- Enum.reverse(operations),
        do: assert({:ok, _} = ExternalOperations.accept_terminal(operation.id, {:ok, result}))

    assert {:ok, completed} = Workflows.resume_run(scope, run)
    assert completed.status == :complete
    assert completed.output["value"]["results"] == [[result, result]]
  end

  test "continuation uses the admitted definition after an editor change", %{scope: scope} do
    {:ok, graph} = Workflows.create_graph(scope, graph_attrs(definition: coding_graph()))
    {:ok, run} = Workflows.start_run(scope, graph, nil, executor: :inline)
    [operation] = ExternalOperations.list(scope, run.id)

    changed =
      Map.update!(graph.definition, "nodes", fn [node] ->
        [put_in(node["params"]["instructions"], "A changed task")]
      end)

    assert {:ok, _updated} = Workflows.update_graph(scope, graph, %{definition: changed})

    assert {:ok, _terminal} =
             ExternalOperations.accept_terminal(operation.id, {:ok, coding_result()})

    assert {:ok, completed} = Workflows.resume_run(scope, run)
    assert completed.status == :complete
    assert completed.definition == run.definition
  end

  test "terminal failure blocks downstream effects and remains a run failure", %{scope: scope} do
    {:ok, graph} =
      Workflows.create_graph(scope, graph_attrs(definition: coding_publication_graph()))

    {:ok, run} = Workflows.start_run(scope, graph, nil, executor: :inline)
    [operation] = ExternalOperations.list(scope, run.id)

    assert {:ok, _operation} =
             ExternalOperations.accept_terminal(
               operation.id,
               {:error, %{"reason" => "checks_failed"}}
             )

    assert {:ok, failed} = Workflows.resume_run(scope, run)
    assert failed.status == :failed
    assert failed.error["details"]["reason"] == "checks_failed"
    assert [consumed] = ExternalOperations.list(scope, run.id)
    assert consumed.status == :consumed
    assert failed.output == nil
  end

  test "external intent cannot be read by a foreign organization or forbidden actor", %{
    scope: scope
  } do
    {:ok, graph} = Workflows.create_graph(scope, graph_attrs(definition: coding_graph()))
    {:ok, run} = Workflows.start_run(scope, graph, nil, executor: :inline)
    [operation] = ExternalOperations.list(scope, run.id)
    other = Hermitscale.AccountsFixtures.organization_scope_fixture()
    assert {:error, :not_found} = ExternalOperations.get(other, operation.id)
    denied = %{scope | membership: %{scope.membership | permissions: []}}
    assert {:error, :forbidden} = ExternalOperations.get(denied, operation.id)
  end

  test "an owner admission committed before handoff is recovered without another conversation", %{
    scope: scope
  } do
    configure(ExternalOperations, adapter: Hermitscale.Workflows.ExternalOperationAdapter)
    {:ok, graph} = Workflows.create_graph(scope, graph_attrs(definition: coding_graph()))
    {:ok, run} = Workflows.start_run(scope, graph, nil, executor: :inline)
    [operation] = ExternalOperations.list(scope, run.id)

    assert {:waiting, resource} =
             Hermitscale.Workflows.ExternalOperationAdapter.dispatch(scope, operation)

    assert {:snooze, 5} = perform_job(ExternalOperationWorker, %{operation_id: operation.id})
    assert {:ok, waiting} = ExternalOperations.get(scope, operation.id)
    assert waiting.resource == resource
    assert [session] = Hermitscale.Agents.list_sessions(scope)
    assert session.id == resource["session_id"]
    assert [turn] = Hermitscale.Agents.list_turns(scope, session.id)
    assert turn.id == resource["id"]
  end

  test "a requested review waits for the exact durable human decision", %{scope: scope} do
    definition =
      coding_graph()
      |> Map.put("nodes", [
        %{
          "id" => "review",
          "type" => "reviews.request",
          "version" => 1,
          "params" => %{
            "action" => "test.action",
            "target_digest" => String.duplicate("a", 64)
          }
        }
      ])

    {:ok, graph} = Workflows.create_graph(scope, graph_attrs(definition: definition))
    {:ok, run} = Workflows.start_run(scope, graph, nil, executor: :inline)
    [operation] = ExternalOperations.list(scope, run.id)
    assert {:snooze, 5} = perform_job(ExternalOperationWorker, %{operation_id: operation.id})
    [review] = Hermitscale.Reviews.list(scope)
    assert review.target_digest == String.duplicate("a", 64)
    assert Workflows.get_run!(scope, run.id).status == :running
    assert Engine.productions(restore(run), "review") == []
    assert {:ok, approved} = Hermitscale.Reviews.decide(scope, review.id, :approved)
    assert approved.status == :approved
    assert {:ok, :complete} = perform_job(ExternalOperationWorker, %{operation_id: operation.id})
    assert {:ok, :advanced} = perform_job(ExternalOperationWorker, %{run_id: run.id})
    complete = Workflows.get_run!(scope, run.id)
    assert complete.status == :complete

    assert [%{"review_id" => id, "decision" => "approved"}] =
             Enum.map(
               complete.output["value"]["review"],
               &Map.take(&1, ["review_id", "decision"])
             )

    assert id == review.id
  end

  defp operation(scope, run, node_id),
    do: Enum.find(ExternalOperations.list(scope, run.id), &(&1.node_id == node_id))

  defp restore(run) do
    {:ok, events} = PostgresStore.stream(run.id, %{repo: Hermitscale.Repo})
    {:ok, workflow} = Replay.restore(events, Compiler.compile!(run.definition))
    workflow
  end

  defp configure(module, options) do
    previous = Application.get_env(:hermitscale, module)
    Application.put_env(:hermitscale, module, options)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hermitscale, module, previous),
        else: Application.delete_env(:hermitscale, module)
    end)
  end
end
