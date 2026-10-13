defmodule Hermitscale.AppSocketPeer do
  @moduledoc false
  use GenServer
  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
  @impl true
  def init(owner), do: {:ok, owner}
  @impl true
  def handle_cast({:ws_send, _caller, _ref, frame}, owner) do
    send(owner, {:app_socket_frame, frame})
    {:noreply, owner}
  end
end
