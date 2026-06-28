defmodule Hermitscale.Workflows.Nodes.AuthoringProbe.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "test.authoring_probe",
    version: 1,
    kind: :step,
    inputs: [:main],
    outputs: [:main],
    default_policy: %{backoff: "linear", max_retries: 1, timeout_ms: 10},
    params: [
      count: [type: :non_neg_integer, required: true, doc: "Even count."],
      flag: [type: :boolean, default: false, doc: "Optional flag."]
    ]

  require Runic

  @impl true
  def validate_params(%{count: count}) when rem(count, 2) == 0, do: :ok
  def validate_params(_params), do: {:error, "count must be even"}

  @impl true
  def build(%{count: count, flag: flag}, %{name: name}) do
    Runic.step(
      fn input -> Map.put(input, :authoring_probe, %{count: ^count, flag: ^flag}) end,
      name: name
    )
  end
end
