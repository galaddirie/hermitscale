defmodule Hermitscale.AppsRuntimeFake do
  @moduledoc false
  use Agent
  @behaviour Hermitscale.Workspaces.Management

  def start_link(_opts),
    do:
      Agent.start_link(
        fn ->
          %{
            calls: [],
            service: nil,
            access: :private,
            app_response: nil,
            source_commit: String.duplicate("a", 40)
          }
        end,
        name: __MODULE__
      )

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  def clear_calls, do: Agent.update(__MODULE__, &%{&1 | calls: []})
  def app_response(response), do: Agent.update(__MODULE__, &%{&1 | app_response: response})
  def no_commit, do: Agent.update(__MODULE__, &%{&1 | source_commit: nil})

  @impl true
  def ensure_allocated(workspace) do
    record({:allocate, workspace.id})
    {:ok, %{compute_state: :sleeping}}
  end

  @impl true
  def verify_termination(_workspace, _lease, %{"receipt" => "app-fixture"}), do: :ok

  def termination_evidence(workspace, lease) do
    record({:terminate, workspace.id})

    {:ok,
     %{
       "workspace_id" => workspace.id,
       "lease_id" => lease.id,
       "operation_key" => lease.operation_key,
       "generation" => lease.generation,
       "writer_stopped" => true,
       "receipt" => "app-fixture"
     }}
  end

  def execute_command(workspace, _lease, "git rev-parse HEAD") do
    record({:git_revision, workspace.id})

    case Agent.get(__MODULE__, & &1.source_commit) do
      nil -> {:ok, %{exit_code: 128, output: "No commit"}}
      sha -> {:ok, %{exit_code: 0, output: sha <> "\n"}}
    end
  end

  def ensure_service(workspace, name, spec) do
    record({:start_service, workspace.id, name, spec})
    Agent.update(__MODULE__, &%{&1 | service: spec})
    {:ok, %{name: name, status: "running"}}
  end

  def stop_service(workspace, name) do
    record({:stop_service, workspace.id, name})
    Agent.update(__MODULE__, &%{&1 | service: nil})
    {:ok, %{name: name, status: "stopped"}}
  end

  def set_app_access(workspace, access) do
    record({:access, workspace.id, access})
    Agent.update(__MODULE__, &%{&1 | access: access})
    :ok
  end

  def app_url(workspace), do: {:ok, "https://#{workspace.id}.sprites.app"}

  def service_logs(workspace, limit) do
    record({:logs, workspace.id, limit})
    {:ok, "App started\n"}
  end

  def app_request(workspace, path, opts) do
    record({:app_request, workspace.id, path, opts})
    {:ok, Agent.get(__MODULE__, & &1.app_response)}
  end

  defp record(call), do: Agent.update(__MODULE__, &%{&1 | calls: [call | &1.calls]})
end
