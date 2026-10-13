defmodule HermitscaleWeb.MCPTest do
  use HermitscaleWeb.ConnCase, async: false

  import Hermitscale.ProductFixtures

  alias Hermitscale.AuthTest.Provider
  alias Hermitscale.Integrations.Capability
  alias Hermitscale.Repo

  @modern_version "2026-07-28"
  @legacy_version "2025-11-25"

  setup do
    authentication = authenticated_product_fixture()
    %{scope: authentication.current_scope}
  end

  describe "protocol transport" do
    test "modern discovery and the tool catalog are stateless and preserve the call budget", %{
      scope: scope
    } do
      graph = product_graph_fixture(scope)

      issued =
        product_capability_fixture(scope, [graph.id], ["workflows.inspect", "workflows.validate"],
          max_calls: 2
        )

      conn = rpc(issued.token, "server/discover")
      discovery = json_response(conn, 200)

      assert discovery["jsonrpc"] == "2.0"
      assert @modern_version in discovery["result"]["supportedVersions"]
      assert @legacy_version in discovery["result"]["supportedVersions"]

      assert discovery["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] ==
               "hermitscale"

      assert Map.keys(discovery["result"]["capabilities"]) == ["tools"]
      assert get_resp_header(conn, "mcp-protocol-version") == [@modern_version]
      assert get_resp_header(conn, "mcp-session-id") == []

      listed = rpc(issued.token, "tools/list") |> json_response(200)
      names = Enum.map(listed["result"]["tools"], & &1["name"])
      assert Enum.sort(names) == ["workflows.inspect", "workflows.validate"]

      assert Enum.all?(listed["result"]["tools"], fn tool ->
               tool["inputSchema"]["type"] == "object" and
                 tool["inputSchema"]["additionalProperties"] == false
             end)

      assert remaining_calls(issued) == 2
    end

    test "legacy initialization negotiates a server-issued session and supports notifications", %{
      scope: scope
    } do
      issued = product_capability_fixture(scope, [], ["workflows.list"], max_calls: 2)
      {session, initialized} = initialize(issued.token)

      assert initialized["result"]["protocolVersion"] == @legacy_version
      assert initialized["result"]["serverInfo"]["name"] == "hermitscale"
      assert Map.keys(initialized["result"]["capabilities"]) == ["tools"]

      notification =
        legacy_rpc(issued.token, session, "notifications/initialized", %{}, notification: true)

      assert response(notification, 202) == ""
      listed = legacy_rpc(issued.token, session, "tools/list") |> json_response(200)
      assert Enum.map(listed["result"]["tools"], & &1["name"]) == ["workflows.list"]
      assert remaining_calls(issued) == 2

      deleted = request(issued.token, "DELETE", "", legacy_headers(session))
      assert response(deleted, 204) == ""
      assert legacy_rpc(issued.token, session, "tools/list").status == 404
    end

    test "legacy requests require initialization, matching protocol headers and fresh IDs", %{
      scope: scope
    } do
      issued = product_capability_fixture(scope, [], ["workflows.list"], max_calls: 3)

      missing =
        request(issued.token, "POST", envelope("tools/list", %{}), [
          {"mcp-protocol-version", @legacy_version}
        ])

      assert missing.status == 400
      {session, _initialized} = initialize(issued.token)

      mismatched =
        request(issued.token, "POST", envelope("tools/list", %{}), [
          {"mcp-session-id", session},
          {"mcp-protocol-version", "2025-06-18"}
        ])

      assert mismatched.status == 400
      assert json_response(mismatched, 400)["error"]["code"] == -32600

      repeated = envelope("tools/call", %{"name" => "workflows.list", "arguments" => %{}})
      assert request(issued.token, "POST", repeated, legacy_headers(session)).status == 200
      assert remaining_calls(issued) == 2
      duplicate = request(issued.token, "POST", repeated, legacy_headers(session))
      assert json_response(duplicate, 400)["error"]["data"]["type"] == "duplicate_request_id"
      assert remaining_calls(issued) == 2
    end

    test "malformed JSON and batch envelopes fail before executing a tool", %{scope: scope} do
      graph = product_graph_fixture(scope)
      issued = product_capability_fixture(scope, [graph.id], ["workflows.inspect"], max_calls: 2)

      malformed = request(issued.token, "POST", "{invalid json", modern_headers("tools/list"))
      assert json_response(malformed, 400)["error"]["code"] == -32700

      batch = [modern_envelope("tools/call", inspect_params(graph.id))]
      rejected = request(issued.token, "POST", batch, modern_headers("tools/call", graph.id))
      assert json_response(rejected, 400)["error"]["code"] == -32600
      assert remaining_calls(issued) == 2
    end

    test "unknown methods return a protocol error and modern initialize is unavailable", %{
      scope: scope
    } do
      issued = product_capability_fixture(scope, [], ["workflows.list"])
      unknown = rpc(issued.token, "unknown/method") |> json_response(404)
      assert unknown["error"]["code"] == -32601
      refute Map.has_key?(unknown, "result")

      unavailable = rpc(issued.token, "initialize") |> json_response(404)
      assert unavailable["error"]["code"] == -32601
    end

    test "modern request metadata and HTTP routing headers must agree", %{scope: scope} do
      graph = product_graph_fixture(scope)
      issued = product_capability_fixture(scope, [graph.id], ["workflows.inspect"], max_calls: 2)
      message = modern_envelope("tools/call", inspect_params(graph.id))

      mismatched =
        request(issued.token, "POST", message, [
          {"mcp-protocol-version", @modern_version},
          {"mcp-method", "tools/list"},
          {"mcp-name", "workflows.inspect"}
        ])

      assert mismatched.status == 400
      assert Map.has_key?(json_response(mismatched, 400), "error")

      without_capabilities =
        put_in(message, ["params", "_meta"], %{
          "io.modelcontextprotocol/protocolVersion" => @modern_version
        })

      invalid =
        request(
          issued.token,
          "POST",
          without_capabilities,
          modern_headers("tools/call", "workflows.inspect")
        )

      assert json_response(invalid, 400)["error"]["code"] == -32602
      assert remaining_calls(issued) == 2
    end

    test "tool-call notifications do not execute or consume authority", %{scope: scope} do
      graph = product_graph_fixture(scope)
      issued = product_capability_fixture(scope, [graph.id], ["workflows.inspect"], max_calls: 1)

      conn = rpc(issued.token, "tools/call", inspect_params(graph.id), notification: true)
      assert response(conn, 202) == ""
      assert remaining_calls(issued) == 1
    end

    test "protocol cancellation cannot mark another request as cancelled", %{scope: scope} do
      issued = product_capability_fixture(scope, [], ["workflows.list"], max_calls: 1)
      request_id = "mcp-cancellation-#{System.unique_integer([:positive])}"
      on_exit(fn -> ExMCP.Server.Cancellation.clear(request_id) end)

      conn =
        rpc(issued.token, "notifications/cancelled", %{"requestId" => request_id},
          notification: true
        )

      assert response(conn, 202) == ""
      refute ExMCP.Server.Cancellation.cancelled?(request_id)
      assert remaining_calls(issued) == 1
    end

    test "unexpected hosts and oversized bodies are rejected before execution", %{scope: scope} do
      issued = product_capability_fixture(scope, [], ["workflows.list"], max_calls: 1)

      untrusted =
        rpc(issued.token, "tools/call", %{"name" => "workflows.list", "arguments" => %{}},
          headers: [{"host", "untrusted.example"}]
        )

      assert untrusted.status == 421

      oversized =
        request(
          issued.token,
          "POST",
          String.duplicate(" ", 1_000_001),
          modern_headers("tools/call", "workflows.list")
        )

      assert oversized.status == 413
      assert remaining_calls(issued) == 1
    end

    test "unexpected browser origins are rejected before a call", %{scope: scope} do
      graph = product_graph_fixture(scope)
      issued = product_capability_fixture(scope, [graph.id], ["workflows.inspect"], max_calls: 1)

      conn =
        rpc(issued.token, "tools/call", inspect_params(graph.id),
          headers: [{"origin", "https://untrusted.example"}]
        )

      assert response(conn, 403) == "Origin not allowed"
      assert remaining_calls(issued) == 1
    end

    test "unsupported logging and subscriptions do not change server state", %{scope: scope} do
      issued = product_capability_fixture(scope, [], ["workflows.list"], max_calls: 2)
      log_level = Logger.level()

      rejected =
        rpc(issued.token, "logging/setLevel", %{"level" => "debug"}) |> json_response(404)

      assert rejected["error"]["code"] == -32601
      assert Logger.level() == log_level

      subscription =
        rpc(issued.token, "subscriptions/listen", %{
          "notifications" => %{"toolsListChanged" => true}
        })
        |> json_response(200)

      assert Map.has_key?(subscription, "error")
      assert remaining_calls(issued) == 2
    end
  end

  describe "capability boundaries" do
    test "unknown and reserved tool names cannot consume protocol authority", %{scope: scope} do
      issued = product_capability_fixture(scope, [], ["workflows.list"], max_calls: 2)

      for name <- ["protocol", "unknown.tool"] do
        rejected =
          rpc(issued.token, "tools/call", %{"name" => name, "arguments" => %{}})
          |> json_response(200)

        assert rejected["result"]["isError"]
      end

      assert remaining_calls(issued) == 2
    end

    test "tool calls return stored resources and consume the retained budget", %{scope: scope} do
      graph = product_graph_fixture(scope)
      issued = product_capability_fixture(scope, [graph.id], ["workflows.inspect"], max_calls: 1)
      result = rpc(issued.token, "tools/call", inspect_params(graph.id)) |> json_response(200)

      assert result["result"]["isError"] == false
      assert result["result"]["structuredContent"]["result"]["id"] == graph.id
      assert remaining_calls(issued) == 0

      exhausted = rpc(issued.token, "tools/call", inspect_params(graph.id)) |> json_response(401)
      assert exhausted["error"]["message"] =~ "execution_budget_exceeded"
    end

    test "action and resource restrictions survive SDK dispatch and scope lists", %{scope: scope} do
      graph = product_graph_fixture(scope)
      other = product_graph_fixture(scope)

      issued =
        product_capability_fixture(scope, [graph.id], ["workflows.inspect", "workflows.list"],
          max_calls: 3
        )

      outside = rpc(issued.token, "tools/call", inspect_params(other.id)) |> json_response(200)
      assert outside["result"]["isError"]

      unlisted =
        rpc(issued.token, "tools/call", %{
          "name" => "workflows.validate",
          "arguments" => %{"definition" => graph.definition}
        })
        |> json_response(200)

      assert unlisted["result"]["isError"]
      assert remaining_calls(issued) == 3

      listed =
        rpc(issued.token, "tools/call", %{"name" => "workflows.list", "arguments" => %{}})
        |> json_response(200)

      assert Enum.map(listed["result"]["structuredContent"]["result"], & &1["id"]) == [graph.id]

      missing =
        rpc(issued.token, "tools/call", %{"name" => "workflows.inspect", "arguments" => %{}})
        |> json_response(200)

      assert missing["result"]["isError"]
    end

    test "foreign organization identifiers remain inaccessible when named in a capability", %{
      scope: scope
    } do
      foreign = Hermitscale.AccountsFixtures.organization_scope_fixture()
      graph = product_graph_fixture(foreign)
      issued = product_capability_fixture(scope, [graph.id], ["workflows.inspect"])
      result = rpc(issued.token, "tools/call", inspect_params(graph.id)) |> json_response(200)

      assert result["result"]["isError"]
      assert hd(result["result"]["content"])["text"] =~ "not_found"
    end

    test "protocol metadata does not become product arguments or delegated authority", %{
      scope: scope
    } do
      graph = product_graph_fixture(scope)
      other = product_graph_fixture(scope)
      issued = product_capability_fixture(scope, [graph.id], ["workflows.inspect"], max_calls: 2)

      result =
        rpc(issued.token, "tools/call", inspect_params(graph.id),
          meta: %{"hermitscale.example/resourceIds" => [other.id]}
        )
        |> json_response(200)

      assert result["result"]["isError"] == false
      assert result["result"]["structuredContent"]["result"]["id"] == graph.id

      denied =
        rpc(issued.token, "tools/call", %{
          "name" => "workflows.inspect",
          "arguments" => %{"id" => other.id, "_meta" => %{"resourceIds" => [other.id]}}
        })
        |> json_response(200)

      assert denied["result"]["isError"]
      assert remaining_calls(issued) == 1
    end

    test "protocol parameter errors and product schema errors return their respective results", %{
      scope: scope
    } do
      graph = product_graph_fixture(scope)
      issued = product_capability_fixture(scope, [graph.id], ["workflows.inspect"])

      malformed =
        rpc(issued.token, "tools/call", %{"name" => "workflows.inspect", "arguments" => []})
        |> json_response(400)

      assert malformed["error"]["code"] == -32602

      invalid =
        rpc(issued.token, "tools/call", %{
          "name" => "workflows.inspect",
          "arguments" => %{"id" => graph.id, "unknown" => "value"}
        })
        |> json_response(200)

      assert invalid["result"]["isError"]
      assert hd(invalid["result"]["content"])["text"] =~ "invalid_arguments"
    end

    test "missing, expired and revoked actor authority is rejected on every HTTP method", %{
      scope: scope
    } do
      for method <- ["POST", "GET", "DELETE"] do
        conn = request(nil, method, modern_envelope("server/discover", %{}))
        assert conn.status == 401
        assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      end

      expired = product_capability_fixture(scope, ["graph"], ["workflows.inspect"])
      expire_fixture(expired.record)
      assert rpc(expired.token, "server/discover").status == 401

      current = product_capability_fixture(scope, ["graph"], ["workflows.inspect"])
      :ok = Provider.remove_membership("membership:owner")
      response = rpc(current.token, "server/discover") |> json_response(401)
      assert response["error"]["message"] =~ "execution_actor_ineligible"
    end

    test "legacy sessions are bound to a capability and revalidate revocation between calls", %{
      scope: scope
    } do
      graph = product_graph_fixture(scope)
      issued = product_capability_fixture(scope, [graph.id], ["workflows.inspect"])
      other_capability = product_capability_fixture(scope, [graph.id], ["workflows.inspect"])
      {session, _initialized} = initialize(issued.token)

      assert legacy_rpc(other_capability.token, session, "tools/list").status == 404

      inspected =
        legacy_rpc(issued.token, session, "tools/call", inspect_params(graph.id))
        |> json_response(200)

      assert inspected["result"]["structuredContent"]["result"]["id"] == graph.id

      issued.record
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
      |> Repo.update!()

      rejected = legacy_rpc(issued.token, session, "tools/list") |> json_response(401)
      assert rejected["error"]["message"] =~ "capability_revoked"
    end
  end

  defp initialize(token) do
    conn =
      request(
        token,
        "POST",
        envelope("initialize", %{
          "protocolVersion" => @legacy_version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "hermitscale-test", "version" => "1.0.0"}
        })
      )

    initialized = json_response(conn, 200)
    [session] = get_resp_header(conn, "mcp-session-id")
    on_exit(fn -> ExMCP.SessionManager.terminate_session(session) end)
    {session, initialized}
  end

  defp rpc(token, method, params \\ %{}, options \\ []) do
    message = modern_envelope(method, params, options)

    headers =
      modern_headers(method, Map.get(params, "name")) ++ Keyword.get(options, :headers, [])

    request(token, "POST", message, headers)
  end

  defp legacy_rpc(token, session, method, params \\ %{}, options \\ []) do
    request(token, "POST", envelope(method, params, options), legacy_headers(session))
  end

  defp modern_envelope(method, params, options \\ []) do
    metadata =
      Map.merge(
        %{
          "io.modelcontextprotocol/protocolVersion" => @modern_version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        Keyword.get(options, :meta, %{})
      )

    envelope(method, Map.put(params, "_meta", metadata), options)
  end

  defp envelope(method, params, options \\ []) do
    message = %{"jsonrpc" => "2.0", "method" => method, "params" => params}

    if Keyword.get(options, :notification, false),
      do: message,
      else: Map.put(message, "id", System.unique_integer([:positive]))
  end

  defp modern_headers(method, name \\ nil) do
    headers = [{"mcp-protocol-version", @modern_version}, {"mcp-method", method}]
    if name, do: [{"mcp-name", name} | headers], else: headers
  end

  defp legacy_headers(session),
    do: [{"mcp-protocol-version", @legacy_version}, {"mcp-session-id", session}]

  defp request(token, method, message, headers \\ []) do
    body = if is_binary(message), do: message, else: Jason.encode!(message)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    conn = %{conn | host: URI.parse(HermitscaleWeb.Endpoint.url()).host}

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn

    conn =
      Enum.reduce(headers, conn, fn
        {"host", host}, conn -> %{conn | host: host}
        {name, value}, conn -> put_req_header(conn, name, value)
      end)

    dispatch(conn, @endpoint, method, "/mcp", body)
  end

  defp inspect_params(id), do: %{"name" => "workflows.inspect", "arguments" => %{"id" => id}}
  defp remaining_calls(issued), do: Repo.get!(Capability, issued.record.id).remaining_calls
end
