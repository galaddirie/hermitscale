defmodule Hermitscale.Workspaces.Management do
  @moduledoc "Private resource adapter contract. Writer termination requires independent verification."
  alias Hermitscale.Workspaces.{Lease, Workspace}

  @callback ensure_allocated(Workspace.t()) :: {:ok, %{compute_state: atom()}} | {:error, atom()}
  @callback verify_termination(Workspace.t(), Lease.t(), map()) :: :ok | {:error, atom()}
end
