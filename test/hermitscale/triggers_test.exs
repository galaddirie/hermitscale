defmodule Hermitscale.TriggersTest do
  use Hermitscale.DataCase, async: false

  import Hermitscale.AccountsFixtures
  import Hermitscale.TriggersFixtures

  alias Hermitscale.Triggers
  alias Hermitscale.Triggers.Trigger
  alias Hermitscale.Workflows
  alias Hermitscale.Workflows.Run

  setup do
    %{scope: user_scope_fixture()}
  end

  describe "organization permissions" do
    test "runners can fire but cannot activate or manage automation", %{scope: scope} do
      {graph, trigger} = activate_trigger_graph!(scope, manual_trigger_node())
      runner = put_in(scope.membership.permissions, ["workflows:run"])
      assert {:error, :forbidden} = Triggers.activate_graph(runner, graph)
      assert {:error, :forbidden} = Triggers.enable_trigger(runner, trigger)
      assert {:error, :forbidden} = Triggers.deactivate_graph(runner, graph)
      assert {:error, :forbidden} = Triggers.disable_trigger(runner, trigger)

      assert {:ok, run} =
               Triggers.fire_manual(runner, trigger, %{}, run_opts: [executor: :inline])

      assert run.execution_actor_user_id == runner.user.id
      assert run.trigger_id == trigger.id
    end
  end

  describe "activation" do
    test "activates a graph and derives one trigger row per trigger node", %{scope: scope} do
      graph = create_graph!(scope, trigger_graph(manual_trigger_node()))

      assert {:ok, %{graph: graph, triggers: [trigger]}} =
               Triggers.activate_graph(scope, graph)

      assert graph.status == :active
      assert %Trigger{node_id: "start", type: "trigger.manual", mode: :manual} = trigger
      assert trigger.status == :enabled
    end

    test "requires at least one trigger node", %{scope: scope} do
      definition = Hermitscale.WorkflowsFixtures.valid_join_graph()

      graph =
        create_graph!(
          scope,
          %{definition | "id" => "wf_no_triggers", "name" => "no_triggers"}
        )

      assert {:error, :no_triggers} = Triggers.activate_graph(scope, graph)
    end

    test "rejects a graph owned by another organization", %{scope: scope} do
      other_scope = organization_scope_fixture(scope.user, organization_fixture())
      graph = create_graph!(other_scope, trigger_graph(manual_trigger_node()))

      assert_raise MatchError, fn ->
        Triggers.activate_graph(scope, graph)
      end
    end

    test "webhook activation generates a token and preserves it across re-activation", %{
      scope: scope
    } do
      {graph, trigger} = activate_trigger_graph!(scope, webhook_trigger_node())

      assert is_binary(trigger.webhook_token)

      {:ok, %{triggers: [reactivated]}} = Triggers.activate_graph(scope, graph)
      assert reactivated.id == trigger.id
      assert reactivated.webhook_token == trigger.webhook_token
    end

    test "schedule activation computes next_fire_at", %{scope: scope} do
      {_graph, trigger} = activate_trigger_graph!(scope, schedule_trigger_node())

      assert %DateTime{} = trigger.next_fire_at
      assert DateTime.after?(trigger.next_fire_at, DateTime.utc_now())
    end

    test "polling activation initializes the cursor and preserves it when config is unchanged", %{
      scope: scope
    } do
      {graph, trigger} = activate_trigger_graph!(scope, polling_trigger_node())

      assert trigger.cursor == %{"count" => 0}

      :ok = Triggers.persist_cursor(trigger, %{"count" => 7})
      {:ok, %{triggers: [reactivated]}} = Triggers.activate_graph(scope, graph)
      assert reactivated.cursor == %{"count" => 7}
    end

    test "polling re-activation with changed config re-initializes the cursor", %{scope: scope} do
      {graph, trigger} = activate_trigger_graph!(scope, polling_trigger_node())
      :ok = Triggers.persist_cursor(trigger, %{"count" => 7})

      definition =
        update_in(graph.definition, ["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "poll"} = node -> put_in(node["params"]["behavior"], "quiet")
            node -> node
          end)
        end)

      {:ok, graph} = Workflows.update_graph(scope, graph, %{definition: definition})
      {:ok, %{triggers: [reactivated]}} = Triggers.activate_graph(scope, graph)

      assert reactivated.cursor == %{"count" => 0}
    end

    test "polling uses the explicitly recorded activation actor", %{scope: scope} do
      {graph, trigger} = activate_trigger_graph!(scope, polling_trigger_node())
      assert trigger.execution_actor_user_id == scope.user.id

      assert {:ok, %{account_id: "data_test", execution_context: context}} =
               Triggers.credentials_for(trigger)

      assert context.actor_user_id == scope.user.id
      collaborator = organization_scope_fixture(user_fixture(), scope.organization)
      {:ok, disabled} = Triggers.disable_trigger(collaborator, trigger)
      {:ok, enabled} = Triggers.enable_trigger(collaborator, disabled)
      assert enabled.execution_actor_user_id == scope.user.id
      {:ok, reassigned} = Triggers.reassign_actor(collaborator, enabled)
      assert reassigned.execution_actor_user_id == collaborator.user.id
      assert graph.org_id == collaborator.organization.id
    end

    test "removes trigger rows for deleted trigger nodes", %{scope: scope} do
      {graph, trigger} = activate_trigger_graph!(scope, webhook_trigger_node())

      definition =
        graph.definition
        |> Map.put("nodes", [
          manual_trigger_node(),
          %{"id" => "echo", "type" => "test.identity_probe", "version" => 1, "params" => %{}}
        ])
        |> Map.put("connections", [%{"from" => "start", "to" => "echo"}])

      {:ok, graph} = Workflows.update_graph(scope, graph, %{definition: definition})
      {:ok, %{triggers: [manual]}} = Triggers.activate_graph(scope, graph)

      assert manual.node_id == "start"
      assert Repo.get(Trigger, trigger.id) == nil
    end

    test "deactivation disables triggers and keeps their rows", %{scope: scope} do
      {graph, trigger} = activate_trigger_graph!(scope, webhook_trigger_node())

      assert {:ok, graph} = Triggers.deactivate_graph(scope, graph)
      assert graph.status == :draft

      kept = Repo.get!(Trigger, trigger.id)
      assert kept.status == :disabled
      assert kept.webhook_token == trigger.webhook_token
    end

    test "deactivation reloads a graph whose supplied status is stale", %{scope: scope} do
      draft = create_graph!(scope, trigger_graph(webhook_trigger_node()))
      {:ok, %{triggers: [trigger]}} = Triggers.activate_graph(scope, draft)

      assert {:ok, %{status: :draft}} = Triggers.deactivate_graph(scope, draft)
      assert Workflows.get_graph!(scope, draft.id).status == :draft
      assert Repo.get!(Trigger, trigger.id).status == :disabled
    end

    test "a forged organization on a supplied foreign graph cannot deactivate it", %{scope: scope} do
      other_scope = organization_scope_fixture(scope.user, organization_fixture())
      {graph, trigger} = activate_trigger_graph!(other_scope, webhook_trigger_node())
      forged = %{graph | org_id: scope.organization.id}

      assert_raise Ecto.NoResultsError, fn -> Triggers.deactivate_graph(scope, forged) end
      assert Workflows.get_graph!(other_scope, graph.id).status == :active
      assert Repo.get!(Trigger, trigger.id).status == :enabled
    end

    test "validator rejects connections into a trigger node" do
      definition =
        trigger_graph(manual_trigger_node(), %{
          "connections" => [
            %{"from" => "start", "to" => "echo"},
            %{"from" => "echo", "to" => "start"}
          ]
        })

      assert {:error, issues} = Workflows.validate_graph(definition)
      assert Enum.any?(issues, &(&1.code == :trigger_with_inputs))
    end
  end

  describe "lifecycle" do
    test "enable/disable/mark_errored transition status", %{scope: scope} do
      {_graph, trigger} = activate_trigger_graph!(scope, manual_trigger_node())

      assert {:ok, %{status: :disabled}} = Triggers.disable_trigger(scope, trigger)

      assert {:ok, trigger} =
               Triggers.enable_trigger(scope, Repo.get!(Trigger, trigger.id))

      assert trigger.status == :enabled

      assert {:ok, errored} = Triggers.mark_errored(trigger, :quota_exhausted)
      assert errored.status == :errored
      assert errored.error["action"] == "repair_connection"
    end
  end

  describe "fire_manual/4" do
    test "dispatches a run with the firing envelope as input", %{scope: scope} do
      {_graph, trigger} = activate_trigger_graph!(scope, manual_trigger_node())

      assert {:ok, %Run{} = run} =
               Triggers.fire_manual(scope, trigger, %{"answer" => 42})

      run = Workflows.get_run!(scope, run.id)
      assert run.status == :complete

      envelope = run.input["value"]
      assert envelope["data"] == %{"answer" => 42}
      assert envelope["trigger"]["node_id"] == "start"
      assert envelope["trigger"]["mode"] == "manual"

      # The trigger entry step unwraps the envelope, so downstream nodes (and
      # the run output) see the bare payload.
      assert run.output["value"]["echo"] == [%{"answer" => 42}]
    end
  end

  describe "scoped queries" do
    test "gets and lists triggers for members of the owning organization", %{scope: scope} do
      collaborator_scope = organization_scope_fixture(user_fixture(), scope.organization)
      {graph, trigger} = activate_trigger_graph!(scope, manual_trigger_node())

      assert Triggers.get_trigger!(collaborator_scope, trigger.id) == trigger
      assert Triggers.list_triggers(collaborator_scope, graph) == [trigger]
    end

    test "does not expose triggers after switching organizations", %{scope: scope} do
      other_scope = organization_scope_fixture(scope.user, organization_fixture())
      {graph, trigger} = activate_trigger_graph!(scope, manual_trigger_node())

      assert_raise Ecto.NoResultsError, fn ->
        Triggers.get_trigger!(other_scope, trigger.id)
      end

      assert Triggers.list_triggers(other_scope, graph.id) == []
    end
  end
end
