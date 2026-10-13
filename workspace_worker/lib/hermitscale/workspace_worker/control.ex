defmodule Hermitscale.WorkspaceWorker.Control do
  @moduledoc """
  Private Unix socket listener reached by an authenticated Sprite exec bridge.

  Frames are uint32 big-endian length-prefixed UTF-8 JSON. Each frame contains
  `token` and `command`. The private control token is delivered by the trusted
  bridge, never put in a journal or response. This listener has no HTTP route or
  app-listener integration.
  """
  use GenServer

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  @impl true
  def init(options) do
    path = Keyword.fetch!(options, :socket_path)
    token = Keyword.fetch!(options, :control_token)
    true = is_binary(token) and byte_size(token) >= 32
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)

    # A service supervisor owns this socket path exclusively.
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
    end

    {:ok, socket} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: 4,
        packet_size: 70_000,
        ip: {:local, String.to_charlist(path)}
      ])

    File.chmod!(path, 0o600)

    state = %{
      socket: socket,
      path: path,
      token: token,
      runtime: Keyword.fetch!(options, :runtime),
      tasks: Keyword.fetch!(options, :tasks)
    }

    {:ok, state, {:continue, :accept}}
  end

  @impl true
  def handle_continue(:accept, state) do
    {:ok, task} = Task.Supervisor.start_child(state.tasks, fn -> accept(state) end)
    Process.monitor(task)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state),
    do: {:stop, {:bridge_stopped, reason}, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)
    File.rm!(state.path)
  end

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, "[REDACTED]") |> Map.put(:message, "[REDACTED]")

  defp accept(state) do
    case :gen_tcp.accept(state.socket) do
      {:ok, client} ->
        serve(client, state)
        :gen_tcp.close(client)
        accept(state)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:accept_failed, reason})
    end
  end

  defp serve(socket, state) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, frame} ->
        response =
          with {:ok, %{"token" => token, "command" => command} = envelope} <- JSON.decode(frame),
               true <- map_size(envelope) == 2,
               true <- is_binary(token) and byte_size(token) == byte_size(state.token),
               true <- :crypto.hash_equals(token, state.token) do
            case Hermitscale.WorkspaceWorker.Runtime.execute(state.runtime, command) do
              {:ok, result} -> %{"ok" => true, "result" => result}
              {:error, reason} -> %{"ok" => false, "error" => Atom.to_string(reason)}
            end
          else
            _invalid_external_message ->
              %{"ok" => false, "error" => "unauthorized_or_invalid_frame"}
          end

        :gen_tcp.send(socket, JSON.encode!(response))

      {:error, reason} when reason in [:timeout, :closed, :emsgsize] ->
        :ok
    end
  end
end
