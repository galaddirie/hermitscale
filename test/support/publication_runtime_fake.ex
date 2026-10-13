defmodule Hermitscale.PublicationRuntimeFake do
  @moduledoc false
  use GenServer
  @behaviour Hermitscale.Workspaces.Management

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  @impl true
  def init(options), do: {:ok, %{fail_stop: Keyword.get(options, :fail_stop, false), calls: []}}
  def calls, do: GenServer.call(__MODULE__, :calls)
  @impl true
  def ensure_allocated(_workspace), do: {:ok, %{compute_state: :sleeping}}
  @impl true
  def verify_termination(workspace, lease, evidence),
    do: if(evidence == proof(workspace, lease), do: :ok, else: {:error, :termination_unverified})

  def termination_evidence(workspace, lease), do: {:ok, proof(workspace, lease)}

  def terminate_admitted(workspace, lease),
    do: GenServer.call(__MODULE__, {:terminate, workspace, lease})

  def release_hold(_workspace, _lease), do: :ok
  @impl true
  def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

  def handle_call({:terminate, _workspace, lease}, _from, %{fail_stop: true} = state),
    do:
      {:reply, {:error, :termination_unverified},
       %{state | fail_stop: false, calls: [{:terminate, lease.id} | state.calls]}}

  def handle_call({:terminate, workspace, lease}, _from, state),
    do:
      {:reply, {:ok, proof(workspace, lease)},
       %{state | calls: [{:terminate, lease.id} | state.calls]}}

  defp proof(workspace, lease),
    do: %{
      "workspace_id" => workspace.id,
      "lease_id" => lease.id,
      "operation_key" => lease.operation_key,
      "generation" => lease.generation,
      "writer_stopped" => true,
      "receipt" => "publication-fixture-stop:" <> lease.id
    }
end
