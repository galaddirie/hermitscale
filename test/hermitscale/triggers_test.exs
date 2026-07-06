defmodule Hermitscale.TriggersTest do
  use Hermitscale.DataCase, async: false

  import Hermitscale.TriggersFixtures

  alias Hermitscale.Triggers
  alias Hermitscale.Triggers.Trigger
  alias Hermitscale.Workflows
  alias Hermitscale.Workflows.Run

  describe "activation" do
    test "activates a graph and derives one trigger row per trigger node" do
      graph = create_graph!(trigger_graph(manual_trigger_node()))

      assert {:ok, %{graph: graph, triggers: [trigger]}} = Triggers.activate_graph(graph)
      assert graph.status == :active
      assert %Trigger{node_id: "start", type: "trigger.manual", mode: :manual} = trigger
      assert trigger.status == :enabled
    end

    test "requires at least one trigger node" do
      definition = Hermitscale.WorkflowsFixtures.valid_join_graph()

      graph =
        create_graph!(%{definition | "id" => "wf_no_triggers", "name" => "no_triggers"})

      assert {:error, :no_triggers} = Triggers.activate_graph(graph)
    end

    test "webhook activation generates a token and preserves it across re-activation" do
      {graph, trigger} = activate_trigger_graph!(webhook_trigger_node())

      assert is_binary(trigger.webhook_token)

      {:ok, %{triggers: [reactivated]}} = Triggers.activate_graph(graph)
      assert reactivated.id == trigger.id
      assert reactivated.webhook_token == trigger.webhook_token
    end

    test "schedule activation computes next_fire_at" do
      {_graph, trigger} = activate_trigger_graph!(schedule_trigger_node())

      assert %DateTime{} = trigger.next_fire_at
      assert DateTime.after?(trigger.next_fire_at, DateTime.utc_now())
    end

    test "polling activation initializes the cursor and preserves it when config is unchanged" do
      {graph, trigger} = activate_trigger_graph!(polling_trigger_node())

      assert trigger.cursor == %{"count" => 0}

      :ok = Triggers.persist_cursor(trigger, %{"count" => 7})
      {:ok, %{triggers: [reactivated]}} = Triggers.activate_graph(graph)
      assert reactivated.cursor == %{"count" => 7}
    end

    test "polling re-activation with changed config re-initializes the cursor" do
      {graph, trigger} = activate_trigger_graph!(polling_trigger_node())
      :ok = Triggers.persist_cursor(trigger, %{"count" => 7})

      definition =
        update_in(graph.definition, ["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "poll"} = node -> put_in(node["params"]["behavior"], "quiet")
            node -> node
          end)
        end)

      {:ok, graph} = Workflows.update_graph(graph, %{definition: definition})
      {:ok, %{triggers: [reactivated]}} = Triggers.activate_graph(graph)

      assert reactivated.cursor == %{"count" => 0}
    end

    test "polling activation resolves credentials into the init_cursor ctx" do
      graph =
        create_graph!(
          trigger_graph(polling_trigger_node(), %{
            "credentials" => %{
              "providers" => %{
                "test.credentials" => %{
                  "provider" => "test.credentials",
                  "credential_id" => "cred_1"
                }
              }
            }
          })
        )

      assert {:ok, %{triggers: [trigger]}} = Triggers.activate_graph(graph)
      assert {:ok, %{access_token: "token:cred_1"}} = Triggers.credentials_for(trigger)
    end

    test "polling activation fails with a pointed error on a broken credential binding" do
      graph =
        create_graph!(
          trigger_graph(polling_trigger_node(), %{
            "credentials" => %{
              "providers" => %{
                "test.credentials" => %{"provider" => "test.credentials", "fail" => true}
              }
            }
          })
        )

      assert {:error, {:credentials, "poll", {:credential_fetch_failed, "poll", _, _}}} =
               Triggers.activate_graph(graph)
    end

    test "removes trigger rows for deleted trigger nodes" do
      {graph, trigger} = activate_trigger_graph!(webhook_trigger_node())

      definition =
        graph.definition
        |> Map.put("nodes", [
          manual_trigger_node(),
          %{"id" => "echo", "type" => "test.identity_probe", "version" => 1, "params" => %{}}
        ])
        |> Map.put("connections", [%{"from" => "start", "to" => "echo"}])

      {:ok, graph} = Workflows.update_graph(graph, %{definition: definition})
      {:ok, %{triggers: [manual]}} = Triggers.activate_graph(graph)

      assert manual.node_id == "start"
      assert Repo.get(Trigger, trigger.id) == nil
    end

    test "deactivation disables triggers and keeps their rows" do
      {graph, trigger} = activate_trigger_graph!(webhook_trigger_node())

      assert {:ok, graph} = Triggers.deactivate_graph(graph)
      assert graph.status == :draft

      kept = Repo.get!(Trigger, trigger.id)
      assert kept.status == :disabled
      assert kept.webhook_token == trigger.webhook_token
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
    test "enable/disable/mark_errored transition status" do
      {_graph, trigger} = activate_trigger_graph!(manual_trigger_node())

      assert {:ok, %{status: :disabled}} = Triggers.disable_trigger(trigger)
      assert {:ok, trigger} = Triggers.enable_trigger(Repo.get!(Trigger, trigger.id))
      assert trigger.status == :enabled

      assert {:ok, errored} = Triggers.mark_errored(trigger, :quota_exhausted)
      assert errored.status == :errored
      assert errored.error["message"] =~ "quota_exhausted"
    end
  end

  describe "fire_manual/3" do
    test "dispatches a run with the firing envelope as input" do
      {_graph, trigger} = activate_trigger_graph!(manual_trigger_node())

      assert {:ok, %Run{} = run} = Triggers.fire_manual(trigger, %{"answer" => 42})

      run = Workflows.get_run!(run.id)
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
end
