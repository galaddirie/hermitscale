defmodule Hermitscale.MCP.Server do
  @moduledoc "ExMCP callbacks for the capability-scoped product tool catalog."
  use ExMCP.Server.Handler

  alias Hermitscale.Integrations.ExecutionAccess
  alias Hermitscale.{ProductJSON, ProductTools}

  def server_info, do: %{name: "hermitscale", version: "0.1.0"}
  def capabilities, do: %{"tools" => %{"listChanged" => false}}

  @impl GenServer
  def init(%{token: token}), do: {:ok, %{token: token}}

  @impl GenServer
  def format_status(status), do: Map.put(status, :state, :redacted)

  @impl ExMCP.Server.Handler
  def handle_initialize(_params, state) do
    {:ok, %{serverInfo: server_info(), capabilities: capabilities()}, state}
  end

  @impl ExMCP.Server.Handler
  def handle_list_tools(_cursor, state) do
    case ExecutionAccess.authenticate(state.token, "product", "protocol") do
      {:ok, _scope, capability} ->
        {:ok, ProductTools.definitions(capability.actions), nil, state}

      {:error, reason} ->
        {:error, ExMCP.Error.protocol_error(-32001, inspect(reason)), state}
    end
  end

  @impl ExMCP.Server.Handler
  def handle_call_tool(name, arguments, state) do
    # ExMCP attaches request metadata to arguments; it is not product input.
    arguments = Map.delete(arguments, "_meta")

    result =
      with {:ok, scope, capability} <-
             authenticate_tool(state.token, name, arguments),
           {:ok, _consumed} <- ExecutionAccess.consume(capability),
           {:ok, result} <-
             ProductTools.execute(scope, name, arguments, capability.resource_ids) do
        encoded = ProductJSON.encode(result)

        %{
          content: [%{type: "text", text: Jason.encode!(encoded)}],
          structuredContent: %{result: encoded},
          isError: false
        }
      else
        {:error, reason} ->
          %{
            content: [%{type: "text", text: Jason.encode!(ProductJSON.encode(%{error: reason}))}],
            isError: true
          }
      end

    {:ok, result, state}
  end

  defp authenticate_tool(token, name, arguments) do
    case ProductTools.definitions([name]) do
      [_definition] ->
        ExecutionAccess.authenticate(
          token,
          "product",
          name,
          ProductTools.resource_id(name, arguments)
        )

      [] ->
        {:error, :unknown_tool}
    end
  end

  @impl ExMCP.Server.Handler
  def handle_set_log_level(_level, state) do
    {:error, ExMCP.Error.protocol_error(-32601, "Method not found"), state}
  end
end
