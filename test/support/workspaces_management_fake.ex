defmodule Hermitscale.WorkspacesManagementFake do
  @moduledoc false
  @behaviour Hermitscale.Workspaces.Management

  @impl true
  def ensure_allocated(workspace) do
    send(self(), {:management_allocate, workspace.id})
    {:ok, %{compute_state: :sleeping}}
  end

  @impl true
  def verify_termination(_workspace, _lease, %{"receipt" => "verified-fixture"}) do
    send(self(), :management_termination_verified)
    :ok
  end

  def verify_termination(_workspace, _lease, _evidence), do: {:error, :termination_unverified}

  def termination_evidence(workspace, lease) do
    send(self(), {:management_evidence, lease.id})

    {:ok,
     %{
       "workspace_id" => workspace.id,
       "lease_id" => lease.id,
       "operation_key" => lease.operation_key,
       "generation" => lease.generation,
       "writer_stopped" => true,
       "receipt" => "verified-fixture"
     }}
  end

  def release_hold(_workspace, lease) do
    send(self(), {:management_hold_released, lease.id})
    :ok
  end

  def terminate_admitted(workspace, lease) do
    send(self(), {:management_admitted_terminated, lease.id})
    termination_evidence(workspace, lease)
  end

  def delete(workspace) do
    send(self(), {:management_deleted, workspace.id})
    {:ok, %{}}
  end
end
