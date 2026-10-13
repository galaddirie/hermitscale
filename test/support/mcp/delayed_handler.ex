defmodule Hermitscale.MCPTest.DelayedHandler do
  @moduledoc false
  use ExMCP.Server.Handler

  @impl GenServer
  def init(%{token: _token}), do: {:ok, %{}}

  @impl ExMCP.Server.Handler
  def handle_call_tool("echo", %{"delay_ms" => delay_ms, "text" => text}, state) do
    request_ref = make_ref()
    Process.send_after(self(), {:echo_ready, request_ref}, delay_ms)

    receive do
      {:echo_ready, ^request_ref} ->
        {:ok, %{content: [%{type: "text", text: text}], isError: false}, state}
    end
  end
end
