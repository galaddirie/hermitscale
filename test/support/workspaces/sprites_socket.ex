defmodule Hermitscale.WorkspacesTest.SpritesSocket do
  @behaviour WebSock

  @impl true
  def init(state) do
    send(state.test_pid, {:sprites_socket, self(), state.path, state.query, state.authorization})
    {:ok, state}
  end

  @impl true
  def handle_in({data, opcode: opcode}, state) do
    send(state.test_pid, {:sprites_input, opcode, data})
    {:ok, state}
  end

  @impl true
  def handle_info({:frames, frames}, state), do: {:push, frames, state}

  @impl true
  def terminate(reason, state), do: send(state.test_pid, {:sprites_socket_closed, reason})
end
