defmodule Hermitscale.Triggers.CounterPollProbe.V1 do
  @moduledoc false

  use Hermitscale.Triggers.Behaviour,
    id: "test.counter_poll_probe",
    version: 1,
    mode: :polling,
    requires: [credentials: [provider: "test.credentials"]],
    params: [
      poll_interval_ms: [type: :pos_integer, default: 60_000],
      behavior: [type: {:in, ~w(emit emit_credentials quiet fail)}, default: "emit"]
    ]

  @impl true
  def init_cursor(_params, _ctx), do: {:ok, %{"count" => 0}}

  @impl true
  def poll(%{behavior: "fail"}, _cursor, _ctx), do: {:error, :probe_failure}

  def poll(%{behavior: "quiet"}, cursor, _ctx), do: {:ok, [], cursor}

  def poll(%{behavior: "emit_credentials"}, %{"count" => count}, ctx) do
    tick = count + 1
    token = ctx.credentials && ctx.credentials.access_token
    event = %{payload: %{"tick" => tick, "access_token" => token}, key: "tick-#{tick}"}
    {:ok, [event], %{"count" => tick}}
  end

  def poll(_params, %{"count" => count}, _ctx) do
    tick = count + 1
    event = %{payload: %{"tick" => tick}, key: "tick-#{tick}"}
    {:ok, [event], %{"count" => tick}}
  end
end
