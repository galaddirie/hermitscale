defmodule HermitscaleWeb.AppProxy.WebSocket do
  @moduledoc """
  Relays frames between a visitor's WebSocket and the app's upstream WebSocket,
  opened by `Hermitscale.Workspaces.SpritesClient.url_websocket/3`.

  Bandit runs the handler in the process that accepted the upgrade, which also
  owns the upstream connection, so upstream messages arrive in `handle_info/2`.
  """

  @behaviour WebSock

  # Close codes that are reserved and must not be sent in a close frame.
  @unsendable_close_codes [1005, 1006, 1015]

  @impl true
  def init(%{data: data} = upstream) do
    upstream
    |> Map.delete(:data)
    |> relay_upstream_data(data)
  end

  @impl true
  def handle_in({data, opcode: opcode}, state) do
    case send_upstream(state, {opcode, data}) do
      {:ok, state} -> {:ok, state}
      {:error, state, _reason} -> {:stop, :normal, 1011, state}
    end
  end

  @impl true
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}

        data = for {:data, ref, data} <- responses, ref == state.ref, do: data
        relay_upstream_data(state, IO.iodata_to_binary(data))

      {:error, conn, _reason, _responses} ->
        {:stop, :normal, 1001, %{state | conn: conn}}

      :unknown ->
        {:ok, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state =
      case send_upstream(state, :close) do
        {:ok, state} -> state
        {:error, state, _reason} -> state
      end

    Mint.HTTP.close(state.conn)
  end

  defp relay_upstream_data(state, ""), do: {:ok, state}

  defp relay_upstream_data(state, data) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} -> relay_frames(%{state | websocket: websocket}, frames, [])
      {:error, websocket, _reason} -> {:stop, :normal, 1002, %{state | websocket: websocket}}
    end
  end

  defp relay_frames(state, [], pushes), do: {:push, Enum.reverse(pushes), state}

  defp relay_frames(state, [{opcode, data} | frames], pushes) when opcode in [:text, :binary],
    do: relay_frames(state, frames, [{opcode, data} | pushes])

  defp relay_frames(state, [{:ping, data} | frames], pushes) do
    case send_upstream(state, {:pong, data}) do
      {:ok, state} -> relay_frames(state, frames, pushes)
      {:error, state, _reason} -> {:stop, :normal, 1011, Enum.reverse(pushes), state}
    end
  end

  defp relay_frames(state, [{:pong, _data} | frames], pushes),
    do: relay_frames(state, frames, pushes)

  defp relay_frames(state, [{:close, code, reason} | _frames], pushes),
    do: {:stop, :normal, close_detail(code, reason), Enum.reverse(pushes), state}

  defp relay_frames(state, [{:error, _reason} | _frames], pushes),
    do: {:stop, :normal, 1002, Enum.reverse(pushes), state}

  defp close_detail(code, _reason) when code in @unsendable_close_codes or is_nil(code),
    do: 1000

  defp close_detail(code, reason), do: {code, reason}

  defp send_upstream(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         state = %{state | websocket: websocket},
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, %{state | conn: conn}}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        {:error, %{state | websocket: websocket}, reason}

      {:error, conn, reason} ->
        {:error, %{state | conn: conn}, reason}
    end
  end
end
