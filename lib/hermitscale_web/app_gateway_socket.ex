defmodule HermitscaleWeb.AppGatewaySocket do
  @moduledoc "Bounded app WebSocket transport with expiring access and idle cleanup."
  @behaviour WebSock
  alias Hermitscale.{Apps, Workspaces}
  @max_frame_bytes 1_048_576

  @impl true
  def init(state) do
    with {:ok, pid, ref} <-
           Workspaces.open_app_socket(
             state.access.scope,
             state.access.workspace_id,
             state.path,
             state.headers
           ) do
      monitor = Process.monitor(pid)
      timer = Process.send_after(self(), :check_app_access, access_check_delay(state.access))

      {:ok,
       Map.merge(state, %{
         upstream: pid,
         stream: ref,
         monitor: monitor,
         timer: timer,
         last_activity: System.monotonic_time(:second)
       })}
    else
      {:error, _reason} -> {:stop, :upstream_unavailable, 1013, state}
    end
  end

  @impl true
  def handle_in({payload, [opcode: opcode]}, state) when byte_size(payload) <= @max_frame_bytes do
    :gun.ws_send(state.upstream, state.stream, {opcode, payload})
    {:ok, %{state | last_activity: System.monotonic_time(:second)}}
  end

  def handle_in({_payload, _metadata}, state), do: {:stop, :frame_too_large, 1009, state}

  @impl true
  def handle_info({:gun_ws, pid, ref, {opcode, payload}}, %{upstream: pid, stream: ref} = state)
      when opcode in [:text, :binary] and byte_size(payload) <= @max_frame_bytes do
    {:push, {opcode, payload}, %{state | last_activity: System.monotonic_time(:second)}}
  end

  def handle_info({:gun_ws, pid, ref, :close}, %{upstream: pid, stream: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(
        {:gun_ws, pid, ref, {:close, code, reason}},
        %{upstream: pid, stream: ref} = state
      ),
      do: {:stop, :normal, {code, reason}, state}

  def handle_info({:gun_ws, pid, ref, frame}, %{upstream: pid, stream: ref} = state)
      when frame in [:ping, :pong],
      do: {:ok, state}

  def handle_info({:gun_ws, pid, ref, {opcode, _payload}}, %{upstream: pid, stream: ref} = state)
      when opcode in [:ping, :pong],
      do: {:ok, state}

  def handle_info(
        {:gun_ws, pid, ref, {_opcode, _payload}},
        %{upstream: pid, stream: ref} = state
      ),
      do: {:stop, :frame_too_large, 1009, state}

  def handle_info({:gun_down, pid, _protocol, _reason, _streams}, %{upstream: pid} = state),
    do: {:stop, :upstream_disconnected, 1013, state}

  def handle_info({:gun_error, pid, ref, _reason}, %{upstream: pid, stream: ref} = state),
    do: {:stop, :upstream_unavailable, 1013, state}

  def handle_info({:gun_error, pid, _reason}, %{upstream: pid} = state),
    do: {:stop, :upstream_unavailable, 1013, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: {:stop, :upstream_disconnected, 1013, state}

  def handle_info(:check_app_access, state) do
    case Apps.resolve_access(state.token) do
      {:ok, access} ->
        if System.monotonic_time(:second) - state.last_activity >= 60 do
          {:stop, :idle, 1000, state}
        else
          {:ok,
           %{
             state
             | timer: Process.send_after(self(), :check_app_access, access_check_delay(access))
           }}
        end

      {:error, _reason} ->
        {:stop, :access_expired, 1008, state}
    end
  end

  @impl true
  def terminate(_reason, %{upstream: pid, timer: timer}) do
    Process.cancel_timer(timer)
    :gun.close(pid)
  end

  def terminate(_reason, _state), do: :ok

  defp access_check_delay(%{grant: %{expires_at: expires_at}}),
    do: expires_at |> DateTime.diff(DateTime.utc_now(), :millisecond) |> min(30_000) |> max(1)

  defp access_check_delay(%{grant: nil}), do: 30_000
end
