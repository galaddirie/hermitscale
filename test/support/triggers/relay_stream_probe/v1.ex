defmodule Hermitscale.Triggers.RelayStreamProbe.V1 do
  @moduledoc false

  use Hermitscale.Triggers.Behaviour,
    id: "test.relay_stream_probe",
    version: 1,
    mode: :stream,
    params: [
      behavior: [type: {:in, ~w(connect refuse)}, default: "connect"]
    ]

  @impl true
  def init_stream(%{behavior: "refuse"}, _ctx), do: {:error, :connection_refused}

  def init_stream(_params, _ctx), do: {:ok, %{events: 0}}

  @impl true
  def handle_event({:emit, payload}, state) do
    {:fire, [payload], %{state | events: state.events + 1}}
  end

  def handle_event(:please_reconnect, state), do: {:reconnect, :requested, state}
  def handle_event(_message, state), do: {:noreply, state}
end
