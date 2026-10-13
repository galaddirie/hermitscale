defmodule HermitscaleWeb.MCPClientTest do
  use Hermitscale.DataCase, async: false

  import Hermitscale.ProductFixtures
  import ExUnit.CaptureLog

  alias Hermitscale.Integrations.Capability

  setup do
    authentication = authenticated_product_fixture()

    listener =
      start_supervised!({Bandit, plug: HermitscaleWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    %{scope: authentication.current_scope, url: "http://localhost:#{port}/mcp"}
  end

  describe "ExMCP client interoperability over HTTP" do
    test "modern discovery, selected tools and capability budgets", context do
      verify_client(context, :modern_only, "2026-07-28")
    end

    test "legacy initialization, selected tools and capability budgets", context do
      verify_client(context, :legacy_only, "2025-11-25")
    end
  end

  defp verify_client(%{scope: scope, url: url}, mode, version) do
    graph = product_graph_fixture(scope)
    other = product_graph_fixture(scope)

    issued =
      product_capability_fixture(scope, [graph.id], ["workflows.inspect", "workflows.validate"],
        max_calls: 2
      )

    client =
      start_supervised!(
        {ExMCP.Client,
         transport: :http,
         url: url,
         protocol_mode: mode,
         security: %{auth: {:bearer, issued.token}, origin: nil},
         use_sse: false,
         health_check_interval: nil,
         reconnect: false,
         retry_policy: [max_attempts: 1],
         handshake_timeout: 5_000,
         establish_timeout: 7_000,
         request_timeout: 5_000}
      )

    assert {:ok, %{connection_status: :ready, protocol_version: ^version}} =
             ExMCP.Client.get_status(client, timeout: 5_000)

    assert {:ok, %{"name" => "hermitscale"}} = ExMCP.Client.server_info(client)

    assert {:ok, %{"tools" => %{"listChanged" => false}}} =
             ExMCP.Client.server_capabilities(client)

    assert {:ok, %{"tools" => tools}} =
             ExMCP.Client.list_tools(client, format: :map, timeout: 5_000, retry_policy: false)

    assert Enum.sort(Enum.map(tools, & &1["name"])) == [
             "workflows.inspect",
             "workflows.validate"
           ]

    assert remaining_calls(issued) == 2

    assert {:ok, %{"isError" => false, "structuredContent" => %{"result" => result}}} =
             inspect_workflow(client, graph.id)

    assert result["id"] == graph.id
    assert remaining_calls(issued) == 1

    assert {:ok, %{"isError" => true}} = inspect_workflow(client, other.id)
    assert remaining_calls(issued) == 1

    assert {:ok, %{"isError" => false}} = inspect_workflow(client, graph.id)
    assert remaining_calls(issued) == 0

    capture_log(fn ->
      assert {:error, _authentication_failure} = inspect_workflow(client, graph.id)
    end)

    assert remaining_calls(issued) == 0
  end

  defp inspect_workflow(client, graph_id) do
    ExMCP.Client.call_tool(client, "workflows.inspect", %{"id" => graph_id},
      format: :map,
      timeout: 5_000,
      retry_policy: false
    )
  end

  defp remaining_calls(issued), do: Repo.get!(Capability, issued.record.id).remaining_calls
end
