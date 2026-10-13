defmodule HermitscaleWeb.MCPDeadlineTest do
  use HermitscaleWeb.ConnCase, async: false

  import Hermitscale.ProductFixtures

  alias Hermitscale.MCPTest.DelayedHandler
  alias HermitscaleWeb.MCP

  test "the authenticated HTTP mount allows callbacks longer than the SDK default deadline" do
    authentication = authenticated_product_fixture()
    issued = product_capability_fixture(authentication.current_scope, [], ["workflows.list"])

    request = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => "tools/call",
      "params" => %{
        "name" => "echo",
        "arguments" => %{"delay_ms" => 10_050, "text" => "callback completed"},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(request))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("authorization", "Bearer " <> issued.token)
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", "echo")

    conn = %{conn | host: URI.parse(HermitscaleWeb.Endpoint.url()).host}
    options = MCP.init([]) |> Map.put(:handler, DelayedHandler)
    response = MCP.call(conn, options) |> json_response(200)

    assert response["result"]["isError"] == false
    assert response["result"]["content"] == [%{"type" => "text", "text" => "callback completed"}]
  end
end
