defmodule Hermitscale.SpritesSDKFake do
  @moduledoc false
  def new(token, _options), do: %{token: token}
  def sprite(_client, name), do: %{name: name}

  def spawn(sprite, executable, args, options) do
    ref = make_ref()
    command = %{ref: ref, pid: Process.whereis(__MODULE__)}

    result =
      Agent.get_and_update(__MODULE__, fn state ->
        {[output, code | []], rest} =
          {Enum.take(state.results, 1) |> List.first(), Enum.drop(state.results, 1)}

        {{output, code},
         %{state | results: rest, calls: [{sprite.name, executable, args, options} | state.calls]}}
      end)

    {output, code} = result
    send(self(), {:stdout, %{ref: ref}, output})
    send(self(), {:exit, %{ref: ref}, code})
    {:ok, command}
  end

  def write(_command, _binary), do: :ok
  def close_stdin(_command), do: :ok
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
end
