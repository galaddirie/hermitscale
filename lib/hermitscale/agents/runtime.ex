defmodule Hermitscale.Agents.Runtime do
  @moduledoc "The remote runtime adapter used by durable turn reconciliation."
  def step(scope, session, turn, lease) do
    adapter =
      Application.get_env(:hermitscale, __MODULE__, [])
      |> Keyword.get(:adapter, Hermitscale.Agents.RemoteRuntime)

    adapter.step(scope, session, turn, lease)
  end
end
