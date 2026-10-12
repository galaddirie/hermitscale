defmodule Hermitscale.Triggers.RelayStreamProbe.V1 do
  @moduledoc false

  use Hermitscale.Triggers.Behaviour,
    id: "test.relay_stream_probe",
    version: 1,
    mode: :stream,
    params: [
      behavior: [
        type: {:in, ~w(connect refuse crash invalid terminate_crash)},
        default: "connect"
      ]
    ]

  @impl true
  def init_stream(%{behavior: "refuse"}, _ctx), do: {:error, :connection_refused}
  def init_stream(%{behavior: "crash"}, _ctx), do: raise("stream connect bug")
  def init_stream(%{behavior: "invalid"}, _ctx), do: :invalid_result

  def init_stream(%{behavior: behavior}, _ctx),
    do: {:ok, %{events: 0, terminate_crash?: behavior == "terminate_crash"}}

  @impl true
  def handle_event({:emit, payload}, state) do
    {:fire, [payload], %{state | events: state.events + 1}}
  end

  def handle_event(:please_reconnect, state), do: {:reconnect, :requested, state}
  def handle_event(:crash, _state), do: raise("stream handler bug")
  def handle_event(_message, state), do: {:noreply, state}

  @impl true
  def terminate_stream(_reason, %{terminate_crash?: true}), do: raise("stream cleanup bug")
  def terminate_stream(_reason, _state), do: :ok
end
