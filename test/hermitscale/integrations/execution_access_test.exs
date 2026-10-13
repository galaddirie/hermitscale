defmodule Hermitscale.Integrations.ExecutionAccessTest do
  use Hermitscale.DataCase, async: false
  import Hermitscale.ProductFixtures
  import Hermitscale.AgentsFixtures
  import Hermitscale.IntegrationsFixtures
  alias Hermitscale.AuthTest.Provider
  alias Hermitscale.Integrations.{Capability, ExecutionAccess}
  alias Hermitscale.WorkOSTest.Client, as: Pipes

  setup do
    %{current_scope: scope} = authenticated_product_fixture()
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

    %{scope: scope}
  end

  test "MCP tokens retain a digest and bound actions and resources", %{scope: scope} do
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

    assert {:error, :invalid_capability} =
             ExecutionAccess.authenticate(issued.token, "inference", "responses")
  end

  test "expiration, revocation and current membership invalidate an MCP bearer", %{scope: scope} do
    expired = product_capability_fixture(scope, ["graph"], ["workflows.inspect"])
    expire_fixture(expired.record)

    assert {:error, :capability_expired} =
             ExecutionAccess.authenticate(expired.token, "product", "workflows.inspect", "graph")

    revoked = product_capability_fixture(scope, ["graph"], ["workflows.inspect"])
    :ok = ExecutionAccess.revoke(scope, revoked.record.id)

    assert {:error, :capability_revoked} =
             ExecutionAccess.authenticate(revoked.token, "product", "protocol")

    current = product_capability_fixture(scope, ["graph"], ["workflows.inspect"])
    :ok = Provider.remove_membership("membership:owner")

    assert {:error, :execution_actor_ineligible} =
             ExecutionAccess.authenticate(current.token, "product", "protocol")
  end

  test "locked MCP call limits use retained state without monetary accounting", %{scope: scope} do
    issued = product_capability_fixture(scope, ["graph"], ["workflows.inspect"], max_calls: 2)
    assert {:ok, %{remaining_calls: 1}} = ExecutionAccess.consume(issued.record)
    assert {:ok, %{remaining_calls: 0}} = ExecutionAccess.consume(issued.record)
    assert {:error, :execution_budget_exceeded} = ExecutionAccess.consume(issued.record)

    assert {:error, :execution_budget_exceeded} =
             ExecutionAccess.authenticate(issued.token, "product", "protocol")
  end

  test "coding receives the authorized OpenAI credential without a gateway or rates", %{
    scope: scope
  } do
    session =
      agent_session_fixture(scope, %{
        connection_set: %{"openai" => %{"provider" => "openai", "account_id" => "data_openai"}}
      })

    assert {:ok, env} = ExecutionAccess.provider_env(scope, session)
    assert env == %{"OPENAI_API_KEY" => "provider-secret"}
    assert Repo.aggregate(Capability, :count) == 0
    assert Enum.any?(Pipes.calls(), &match?({:vend_credentials, _}, &1))
  end

  test "provider credential vending revalidates membership and selected account", %{scope: scope} do
    session = agent_session_fixture(scope)
    :ok = Provider.remove_membership("membership:owner")
    assert {:error, :execution_actor_ineligible} = ExecutionAccess.provider_env(scope, session)
    refute Enum.any?(Pipes.calls(), &match?({:vend_credentials, _}, &1))
  end
end
