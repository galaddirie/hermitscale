defmodule HermitscaleWeb.AppProxyTest.UpstreamSocket do
  @behaviour WebSock

  @impl true
  def init(state) do
    send(state.test_pid, {:upstream_socket, self(), state.path, state.headers})
    {:ok, state}
  end

  @impl true
  def handle_in({data, opcode: opcode}, state) do
    {:push, {opcode, "echo:" <> data}, state}
  end

  @impl true
  def handle_info({:frames, frames}, state), do: {:push, frames, state}
  def handle_info({:close, code, reason}, state), do: {:stop, :normal, {code, reason}, state}

  @impl true
  def terminate(reason, state), do: send(state.test_pid, {:upstream_closed, reason})
end
