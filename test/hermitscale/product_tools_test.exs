defmodule Hermitscale.ProductToolsTest do
  use Hermitscale.DataCase, async: false
  import Hermitscale.ProductFixtures
  alias Hermitscale.{ProductTools, Workflows}

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
    :ok = Workflows.subscribe_run(scope, first.id)

    on_exit(fn ->
      Runic.Runner.stop(Hermitscale.WorkflowRunner, first.id, persist: false)
    end)

    assert {:ok, duplicate} = ProductTools.execute(scope, "runs.start", args)
    assert duplicate.id == first.id
    assert first.admission_digest != nil
    assert Repo.aggregate(Hermitscale.Workflows.Run, :count) == 1

    assert {:error, :operation_key_conflict} =
             ProductTools.execute(scope, "runs.start", %{args | "input" => %{"ticket" => "ENG-8"}})

    if Workflows.get_run!(scope, first.id).status != :complete do
      assert_receive {:run_complete, id}, 1_000
      assert id == first.id
    end

    assert Workflows.get_run!(scope, first.id).status == :complete
    assert {:ok, completed} = ProductTools.execute(scope, "runs.start", args)
    assert completed.id == first.id
    assert completed.status == :complete
  end

  test "example workflow domains are not product operations", %{scope: scope} do
    actions =
      ~w(deployments.request deployments.inspect reviews.request reviews.decide support.subscribe support.investigate support.inspect support.reply apps.verify_defect)

    assert ProductTools.definitions(actions) == []

    for action <- actions do
      assert ProductTools.permission(action) == nil
      assert {:error, :unknown_tool} = ProductTools.execute(scope, action, %{})
    end
  end

  test "turn verification is explicit and publishing does not require review resources" do
    [continue] = ProductTools.definitions(["agents.continue"])

    assert continue.inputSchema.properties["verification_commands"] == %{
             type: "array",
             items: %{type: "string"}
           }

    refute "verification_commands" in continue.inputSchema.required

    for tool <- ProductTools.definitions(["agents.publish", "apps.publish"]) do
      refute "review_id" in tool.inputSchema.required
      refute Map.has_key?(tool.inputSchema.properties, "verification_commands")
    end
  end
end
