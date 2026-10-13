defmodule Hermitscale.Workspaces.SpriteSDK do
  @moduledoc false

  def client(token, options), do: {:ok, api().new(token, options)}
  def sprite(client, name), do: {:ok, api().sprite(client, name)}
  def spawn(sprite, command, args, options), do: api().spawn(sprite, command, args, options)
  def close_stdin(command), do: api().close_stdin(command)

  def kill(%{pid: pid}) do
    GenServer.stop(pid, :normal)
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, {:normal, _call} -> :ok
  end

  def api, do: Application.get_env(:hermitscale, :sprites_sdk, Sprites)

  @doc false
  def capture(sprite, executable, args, options \\ []) do
    timeout = Keyword.get(options, :timeout, 30_000)
    limit = Keyword.get(options, :output_limit, 1_500_000)
    stdin = Keyword.get(options, :stdin)

    transport_options =
      options |> Keyword.drop([:output_limit, :stdin]) |> Keyword.put(:stdin, is_binary(stdin))

    with {:ok, command} <- api().spawn(sprite, executable, args, transport_options) do
      case stdin do
        nil -> :ok
        binary when is_binary(binary) -> :ok = api().write(command, binary)
      end

      api().close_stdin(command)
      receive_output(command, System.monotonic_time(:millisecond) + timeout, limit, "")
    else
      {:error, _reason} -> {:error, :sprite_transport_unavailable}
    end
  end

  defp receive_output(%{ref: ref} = command, deadline, limit, output) do
    receive do
      {type, %{ref: ^ref}, data} when type in [:stdout, :stderr] ->
        chunk = IO.iodata_to_binary(data)

        if byte_size(output) + byte_size(chunk) <= limit do
          receive_output(command, deadline, limit, output <> chunk)
        else
          kill(command)
          {:error, :output_limit_exceeded}
        end

      {:exit, %{ref: ^ref}, code} ->
        {:ok, %{output: output, exit_code: code}}

      {:error, %{ref: ^ref}, _reason} ->
        {:error, :sprite_transport_unavailable}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        kill(command)
        {:error, :sprite_command_timeout}
    end
  end
end
