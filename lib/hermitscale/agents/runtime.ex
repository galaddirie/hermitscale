defmodule Hermitscale.Agents.Runtime do
  @moduledoc "The configured remote runtime; durable product records own dispatch and outcomes."
  def adapter,
    do:
      Application.get_env(:hermitscale, __MODULE__, [])
      |> Keyword.get(:adapter, Hermitscale.Agents.RemoteRuntime)

  def qualification, do: %{status: :configured, coordinator: "jido 2.4.0", required: []}
  def ready?, do: true
  def step(scope, session, turn, lease), do: adapter().step(scope, session, turn, lease)

  def preflight(scope, session, turn) do
    if adapter() == Hermitscale.Agents.RemoteRuntime,
      do: adapter().preflight(scope, session, turn),
      else: :ok
  end
end
