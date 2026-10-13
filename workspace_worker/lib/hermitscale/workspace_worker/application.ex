defmodule Hermitscale.WorkspaceWorker.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      case Application.fetch_env!(:workspace_worker, :enabled) do
        false ->
          []

        true ->
          config = Application.fetch_env!(:workspace_worker, :service)

          [
            {Task.Supervisor, name: Hermitscale.WorkspaceWorker.Tasks},
            {Hermitscale.WorkspaceWorker.Journal,
             name: Hermitscale.WorkspaceWorker.Journal,
             path: Keyword.fetch!(config, :journal_path),
             workspace_id: Keyword.fetch!(config, :workspace_id),
             secrets: Keyword.fetch!(config, :secrets),
             provider_env_file: Keyword.fetch!(config, :harness) |> Keyword.fetch!(:env_file)},
            {Hermitscale.WorkspaceWorker.Runtime,
             name: Hermitscale.WorkspaceWorker.Runtime,
             journal: Hermitscale.WorkspaceWorker.Journal,
             adapter: Hermitscale.WorkspaceWorker.Harness,
             config: Keyword.fetch!(config, :harness)},
            {Hermitscale.WorkspaceWorker.Control,
             runtime: Hermitscale.WorkspaceWorker.Runtime,
             tasks: Hermitscale.WorkspaceWorker.Tasks,
             socket_path: Keyword.fetch!(config, :socket_path),
             control_token: Keyword.fetch!(config, :control_token),
             token_deadline: Keyword.fetch!(config, :token_deadline)}
          ]
      end

    # A lost runtime/control process also restarts the journal, producing an
    # explicit uncertain recovery event instead of leaving a stale live handle.
    Supervisor.start_link(children,
      strategy: :one_for_all,
      name: Hermitscale.WorkspaceWorker.Supervisor
    )
  end
end
