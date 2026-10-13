defmodule Hermitscale.Integrations.ExecutionAccessTest do
  use Hermitscale.DataCase, async: false
  import Hermitscale.ProductFixtures
  import Hermitscale.AgentsFixtures
  import Hermitscale.IntegrationsFixtures
  alias Hermitscale.AuthTest.Provider
  alias Hermitscale.Integrations.{Capability, ExecutionAccess, InferenceGateway}
  alias Hermitscale.WorkOSTest.Client, as: Pipes

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    authentication = authenticated_product_fixture()
    scope = authentication.current_scope
    start_supervised!({Pipes, %{}})

    Pipes.put_response(
      :list_org_providers,
      {:ok,
       %{
         "data" => [
           %{
             "slug" => "openai",
             "connected_accounts" => [account_fixture("openai", scope.organization.id)]
           }
         ]
       }}
    )

    Pipes.put_response(
      :vend_credentials,
      {:ok, %{auth_method: "api_key", value: "provider-secret", scopes: [], missing_scopes: []}}
    )

    configure_product_fixture(InferenceGateway,
      rates: %{
        "test-model" => %{
          input_micros_per_million: 1_000_000,
          output_micros_per_million: 2_000_000,
          version: "test-rate-v1"
        }
      }
    )

    %{scope: scope}
  end

  test "only a token digest is retained and actions and resources remain bounded", %{scope: scope} do
    graph = product_graph_fixture(scope)
    issued = product_capability_fixture(scope, [graph.id], ["workflows.inspect"])
    persisted = Repo.get!(Capability, issued.record.id)
    assert persisted.token_digest != issued.token
    refute Map.has_key?(Map.from_struct(persisted), :token)

    assert {:ok, current, cap} =
             ExecutionAccess.authenticate(issued.token, "product", "workflows.inspect", graph.id)

    assert current.user.id == scope.user.id
    assert cap.id == persisted.id

    assert {:error, :capability_action_denied} =
             ExecutionAccess.authenticate(issued.token, "product", "agents.publish", graph.id)

    assert {:error, :capability_resource_denied} =
             ExecutionAccess.authenticate(
               issued.token,
               "product",
               "workflows.inspect",
               "another_graph"
             )

    assert {:error, :invalid_capability} =
             ExecutionAccess.authenticate("unknown", "product", "protocol")

    assert {:error, :invalid_product_capability} =
             ExecutionAccess.issue_product(scope, [graph.id], ["untrusted.internal"])
  end

  test "expiration, revocation and current actor membership invalidate a bearer", %{scope: scope} do
    issued = product_capability_fixture(scope, ["graph"], ["workflows.inspect"])
    expire_fixture(issued.record)

    assert {:error, :capability_expired} =
             ExecutionAccess.authenticate(issued.token, "product", "workflows.inspect", "graph")

    session = agent_session_fixture(scope)
    turn = agent_turn_fixture(scope, session)
    fresh = inference_capability_fixture(scope, turn)
    :ok = ExecutionAccess.revoke(scope, turn.id)

    assert {:error, :capability_revoked} =
             ExecutionAccess.authenticate(fresh.token, "inference", "responses", turn.id)

    current = product_capability_fixture(scope, ["graph"], ["workflows.inspect"])
    :ok = Provider.remove_membership("membership:owner")

    assert {:error, :execution_actor_ineligible} =
             ExecutionAccess.authenticate(current.token, "product", "workflows.inspect", "graph")
  end

  test "reservations use locked state and cannot gain budget from negative costs", %{scope: scope} do
    session = agent_session_fixture(scope)
    turn = agent_turn_fixture(scope, session)

    issued =
      inference_capability_fixture(scope, turn, remaining_calls: 2, remaining_cost_micros: 100)

    assert {:error, :invalid_cost} = ExecutionAccess.consume(issued.record, -1)
    assert {:ok, reserved} = ExecutionAccess.consume(issued.record, 80)
    assert reserved.remaining_cost_micros == 20
    assert reserved.remaining_calls == 1
    assert {:error, :execution_budget_exceeded} = ExecutionAccess.consume(issued.record, 30)
    assert {:ok, last} = ExecutionAccess.consume(issued.record, 20)
    assert last.remaining_cost_micros == 0
    assert last.remaining_calls == 0
    assert {:error, :execution_budget_exceeded} = ExecutionAccess.consume(issued.record, 0)
    expire_fixture(issued.record)
    assert {:error, :execution_budget_exceeded} = ExecutionAccess.consume(issued.record, 0)
  end

  test "model admission rejects invalid output limits, unapproved models and exhausted budgets before HTTP",
       %{scope: scope} do
    session = agent_session_fixture(scope)
    turn = agent_turn_fixture(scope, session)
    issued = inference_capability_fixture(scope, turn, remaining_cost_micros: 1)

    for output <- [-1, 0, "8192", nil] do
      assert {:error, :invalid_model_request} =
               InferenceGateway.request(issued.token, %{
                 "model" => "test-model",
                 "input" => "task",
                 "max_output_tokens" => output
               })
    end

    assert {:error, :model_not_allowed} =
             InferenceGateway.request(issued.token, %{
               "model" => "not-selected",
               "input" => "task"
             })

    assert {:error, :execution_budget_exceeded} =
             InferenceGateway.request(issued.token, %{
               "model" => "test-model",
               "input" => "task",
               "max_output_tokens" => 32
             })

    assert Repo.get!(Capability, issued.record.id).remaining_calls == 5

    refute Enum.any?(Pipes.calls(), fn {operation, _arguments} ->
             operation == :vend_credentials
           end)
  end

  test "model requests recheck the actor before vending credentials", %{scope: scope} do
    session = agent_session_fixture(scope)
    turn = agent_turn_fixture(scope, session)
    issued = inference_capability_fixture(scope, turn)
    :ok = Provider.remove_membership("membership:owner")

    assert {:error, :execution_actor_ineligible} =
             InferenceGateway.request(issued.token, %{
               "model" => "test-model",
               "input" => "task",
               "max_output_tokens" => 32
             })

    refute Enum.any?(Pipes.calls(), fn {operation, _arguments} ->
             operation == :vend_credentials
           end)
  end

  test "provider context references and malformed tools cannot bypass reservation admission", %{
    scope: scope
  } do
    session = agent_session_fixture(scope)
    turn = agent_turn_fixture(scope, session)
    issued = inference_capability_fixture(scope, turn)

    for params <- [
          %{
            "model" => "test-model",
            "input" => [%{"type" => "item_reference", "id" => "msg_external_context"}]
          },
          %{
            "model" => "test-model",
            "input" => "task",
            "previous_response_id" => "resp_previous"
          },
          %{"model" => "test-model", "input" => "task", "conversation" => "conv_previous"},
          %{"model" => "test-model", "input" => "task", "tools" => nil},
          %{"model" => "test-model", "input" => "task", "tools" => %{"type" => "function"}},
          %{
            "model" => "test-model",
            "input" => "task",
            "tools" => [%{"type" => "namespace", "tools" => [%{"type" => "function"}]}]
          },
          %{
            "model" => "test-model",
            "input" => "task",
            "tools" => [%{"type" => "namespace", "name" => "functions", "tools" => []}]
          },
          %{
            "model" => "test-model",
            "input" => "task",
            "tools" => [%{"type" => "namespace", "name" => "functions", "tools" => nil}]
          },
          %{
            "model" => "test-model",
            "input" => "task",
            "tools" => [
              %{
                "type" => "namespace",
                "name" => "functions",
                "tools" => [%{"type" => "web_search"}]
              }
            ]
          },
          %{
            "model" => "test-model",
            "input" => "task",
            "tools" => [
              %{
                "type" => "namespace",
                "name" => "functions",
                "tools" => [
                  %{
                    "type" => "namespace",
                    "name" => "nested",
                    "tools" => [%{"type" => "function"}]
                  }
                ]
              }
            ]
          },
          %{
            "model" => "test-model",
            "input" => "task",
            "tools" => List.duplicate(%{"type" => "function"}, 129)
          },
          %{
            "model" => "test-model",
            "input" => "task",
            "tools" => [
              %{
                "type" => "namespace",
                "name" => "functions",
                "tools" => List.duplicate(%{"type" => "function"}, 129)
              }
            ]
          }
        ] do
      assert {:error, reason} = InferenceGateway.request(issued.token, params)
      assert reason in [:invalid_model_request, :unsupported_model_input]
    end

    assert Repo.get!(Capability, issued.record.id).remaining_cost_micros ==
             issued.record.remaining_cost_micros

    assert Repo.get!(Capability, issued.record.id).remaining_calls ==
             issued.record.remaining_calls

    refute Enum.any?(Pipes.calls(), fn {operation, _arguments} ->
             operation == :vend_credentials
           end)
  end

  test "actual measured usage settles a reservation at a fixed upstream without exposing provider keys",
       %{scope: scope} do
    session = agent_session_fixture(scope)
    turn = agent_turn_fixture(scope, session)
    issued = inference_capability_fixture(scope, turn)

    tools = [
      %{
        "type" => "namespace",
        "name" => "functions",
        "tools" => [
          %{
            "type" => "function",
            "name" => "exec_command",
            "parameters" => %{"type" => "object"}
          },
          %{"type" => "custom", "name" => "apply_patch"}
        ]
      }
    ]

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "api.openai.com"
      assert conn.request_path == "/v1/responses"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer provider-secret"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["tools"] == tools

      Req.Test.json(conn, %{
        "id" => "resp_accounted",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 4},
        "output" => []
      })
    end)

    assert {:ok, response} =
             InferenceGateway.request(
               issued.token,
               %{
                 "model" => "test-model",
                 "input" => "task",
                 "max_output_tokens" => 32,
                 "tools" => tools
               },
               plug: {Req.Test, __MODULE__}
             )

    assert response.status == 200
    assert Repo.get!(Capability, issued.record.id).remaining_cost_micros == 100_000 - 18
    assert Hermitscale.Usage.summary(scope, turn.id).model == %{quantity: 14, cost_micros: 18}
  end

  test "missing or negative usage evidence keeps the reservation rather than issuing a refund", %{
    scope: scope
  } do
    session = agent_session_fixture(scope)
    turn = agent_turn_fixture(scope, session)
    issued = inference_capability_fixture(scope, turn)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "id" => "resp_invalid_usage",
        "usage" => %{"input_tokens" => -10, "output_tokens" => 100}
      })
    end)

    assert {:error, :usage_evidence_missing} =
             InferenceGateway.request(
               issued.token,
               %{"model" => "test-model", "input" => "task", "max_output_tokens" => 32},
               plug: {Req.Test, __MODULE__}
             )

    current = Repo.get!(Capability, issued.record.id)
    assert current.remaining_cost_micros < issued.record.remaining_cost_micros
    assert current.remaining_calls == issued.record.remaining_calls - 1
    assert Hermitscale.Usage.summary(scope, turn.id) == %{}
  end
end
