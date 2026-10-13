defmodule Hermitscale.ProductToolsTest do
  use Hermitscale.DataCase, async: false
  use Oban.Testing, repo: Hermitscale.Repo
  import Hermitscale.ProductFixtures
  alias Hermitscale.{ProductTools, Workflows}
  alias Hermitscale.Workflows.ExternalOperationWorker

  setup do
    authentication = authenticated_product_fixture()
    %{scope: authentication.current_scope}
  end

  test "tool definitions expose product actions and validation runs through the real compiler", %{
    scope: scope
  } do
    definitions = ProductTools.definitions(["workflows.validate", "unknown.tool"])
    assert [%{name: "workflows.validate", inputSchema: %{type: "object"}}] = definitions

    assert {:ok, %{valid: true}} =
             ProductTools.execute(scope, "workflows.validate", %{
               "definition" => Hermitscale.WorkflowsFixtures.completion_probe_graph()
             })

    assert {:error, issues} =
             ProductTools.execute(scope, "workflows.validate", %{"definition" => %{}})

    assert is_list(issues)
    assert {:error, :unknown_tool} = ProductTools.execute(scope, "package.internal", %{})
  end

  test "read operations enforce organization ownership and the tool permission", %{scope: scope} do
    graph = product_graph_fixture(scope)
    assert {:ok, ^graph} = ProductTools.execute(scope, "workflows.inspect", %{"id" => graph.id})
    other = Hermitscale.AccountsFixtures.organization_scope_fixture()

    assert {:error, :not_found} =
             ProductTools.execute(other, "workflows.inspect", %{"id" => graph.id})

    denied = %{scope | membership: %{scope.membership | permissions: []}}
    assert {:error, :forbidden} = ProductTools.execute(denied, "workflows.list", %{})
  end

  test "mutation keys are mandatory and a repeated run start retains one native input", %{
    scope: scope
  } do
    graph = product_graph_fixture(scope)
    args = %{"graph_id" => graph.id, "input" => %{"ticket" => "ENG-7"}}
    assert {:error, :idempotency_key_required} = ProductTools.execute(scope, "runs.start", args)
    args = Map.put(args, "operation_key", Ecto.UUID.generate())
    assert {:ok, first} = ProductTools.execute(scope, "runs.start", args)
    assert {:ok, duplicate} = ProductTools.execute(scope, "runs.start", args)
    assert duplicate.id == first.id
    assert first.admission_digest != nil
    assert Repo.aggregate(Hermitscale.Workflows.Run, :count) == 1
    assert_enqueued(worker: ExternalOperationWorker, args: %{run_id: first.id})

    assert {:error, :operation_key_conflict} =
             ProductTools.execute(scope, "runs.start", %{args | "input" => %{"ticket" => "ENG-8"}})

    assert {:ok, :advanced} = perform_job(ExternalOperationWorker, %{run_id: first.id})
    assert Workflows.get_run!(scope, first.id).status == :complete
    assert {:ok, completed} = ProductTools.execute(scope, "runs.start", args)
    assert completed.id == first.id
    assert completed.status == :complete
  end

  test "review requests and decisions use the public policy contract", %{scope: scope} do
    attrs = review_attrs_fixture() |> Map.new(fn {key, value} -> {to_string(key), value} end)
    assert {:ok, review} = ProductTools.execute(scope, "reviews.request", attrs)
    assert {:ok, duplicate} = ProductTools.execute(scope, "reviews.request", attrs)
    assert duplicate.id == review.id

    assert {:error, :invalid_decision} =
             ProductTools.execute(scope, "reviews.decide", %{
               "id" => review.id,
               "decision" => "perhaps"
             })

    assert {:ok, approved} =
             ProductTools.execute(scope, "reviews.decide", %{
               "id" => review.id,
               "decision" => "approved"
             })

    assert approved.status == :approved
  end
end
