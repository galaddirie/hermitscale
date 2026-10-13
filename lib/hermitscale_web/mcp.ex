defmodule HermitscaleWeb.MCP do
  @moduledoc "Bearer authentication and HTTP mounting for the ExMCP product server."
  @behaviour Plug
  import Plug.Conn

  alias Hermitscale.Integrations.ExecutionAccess
  alias Hermitscale.MCP.Server

  @impl Plug
  def init(_opts) do
    ExMCP.HttpPlug.init(
      handler: Server,
      # Preview provisioning/build/verification can span several remote calls.
      handler_call_timeout: 300_000,
      server_info: Server.server_info(),
      server_capabilities: Server.capabilities(),
      protocol_mode: :prefer_modern,
      path: "/mcp"
    )
  end

  @impl Plug
  def call(conn, opts) do
    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _missing -> nil
      end

    conn = put_resp_header(conn, "cache-control", "no-store")

    case ExecutionAccess.authenticate(token, "product", "protocol") do
      {:ok, _scope, capability} ->
        opts =
          opts
          |> Map.put(:handler_opts, %{token: token})
          |> Map.put(:principal_id, capability.id)
          |> Map.put(:tenant_id, capability.org_id)
          |> Map.put(:allowed_hosts, [URI.parse(HermitscaleWeb.Endpoint.url()).host])

        serve(conn, opts)

      {:error, reason} ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{
            jsonrpc: "2.0",
            id: nil,
            error: %{code: -32001, message: inspect(reason)}
          })
        )
        |> halt()
    end
  end

  defp serve(%Plug.Conn{method: "POST"} = conn, opts) do
    case read_body(conn, length: opts.body_limit, read_length: opts.body_limit) do
      {:ok, body, conn} ->
        # Product cancellation is the scoped, durable agents.cancel operation.
        # Ignore unsupported protocol cancellation before the SDK's global tracker.
        case Jason.decode(body) do
          {:ok, %{"method" => "notifications/cancelled"} = notification}
          when not is_map_key(notification, "id") ->
            conn |> send_resp(202, "") |> halt()

          _request_or_invalid_json ->
            conn |> assign(:raw_body, body) |> ExMCP.HttpPlug.call(opts)
        end

      {:more, _partial, conn} ->
        conn |> send_resp(413, "Request body too large") |> halt()

      {:error, _reason} ->
        conn |> send_resp(400, "Unable to read request body") |> halt()
    end
  end

  defp serve(conn, opts), do: ExMCP.HttpPlug.call(conn, opts)
end
