defmodule Runic.TestSupport.StatelessStore do
  @behaviour Runic.Runner.Store

  @impl Runic.Runner.Store
  def init_store(opts) do
    {:ok,
     %{
       runner_name: Keyword.fetch!(opts, :runner_name),
       repo: Keyword.get(opts, :repo)
     }}
  end

  @impl Runic.Runner.Store
  def save(_workflow_id, _log, _state), do: :ok

  @impl Runic.Runner.Store
  def load(_workflow_id, _state), do: {:error, :not_found}
end
