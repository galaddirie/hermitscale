defmodule Hermitscale.PublicationSDKFake do
  @moduledoc false
  use GenServer
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  @impl true
  def init(options),
    do: {:ok, %{responses: Keyword.fetch!(options, :responses), commands: %{}, requests: []}}

  def new(_token, _options), do: %{}
  def sprite(_client, name), do: %{name: name}

  def spawn(_sprite, _executable, _args, _options),
    do: GenServer.call(__MODULE__, {:spawn, self()})

  def write(%{ref: ref}, body), do: GenServer.call(__MODULE__, {:write, ref, body})
  def close_stdin(%{ref: ref}), do: GenServer.call(__MODULE__, {:close, ref})
  def requests, do: GenServer.call(__MODULE__, :requests)
  @impl true
  def handle_call({:spawn, recipient}, _from, %{responses: [response | responses]} = state) do
    ref = make_ref()
    command = %{recipient: recipient, response: response}

    {:reply, {:ok, %{ref: ref, pid: self()}},
     %{state | commands: Map.put(state.commands, ref, command), responses: responses}}
  end

  def handle_call({:write, ref, body}, _from, state) do
    request = Jason.decode!(body)
    {:reply, :ok, %{state | requests: [{ref, request} | state.requests]}}
  end

  def handle_call({:close, ref}, _from, state) do
    %{recipient: recipient, response: {output, code}} = Map.fetch!(state.commands, ref)
    send(recipient, {:stdout, %{ref: ref}, output})
    send(recipient, {:exit, %{ref: ref}, code})
    {:reply, :ok, %{state | commands: Map.delete(state.commands, ref)}}
  end

  def handle_call(:requests, _from, state),
    do: {:reply, state.requests |> Enum.reverse() |> Enum.map(&elem(&1, 1)), state}
end
