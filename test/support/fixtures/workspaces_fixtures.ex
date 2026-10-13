defmodule Hermitscale.WorkspacesFixtures do
  @moduledoc false

  import Hermitscale.AccountsFixtures

  def workspace_scope_fixture do
    scope = organization_scope_fixture()
    put_in(scope.membership.permissions, ~w(workspaces:read workspaces:write agents:run))
  end

  def workspace_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      repository: "github:example/project",
      base_sha: String.duplicate("a", 40)
    })
  end

  def workspace_fixture(scope, attrs \\ %{}) do
    {:ok, workspace} =
      Hermitscale.Workspaces.ensure_workspace(scope, Ecto.UUID.generate(), workspace_attrs(attrs))

    workspace
  end

  def lease_deadline, do: DateTime.add(DateTime.utc_now(), 300, :second)

  def termination_evidence(lease) do
    %{
      "workspace_id" => lease.workspace_id,
      "lease_id" => lease.id,
      "operation_key" => lease.operation_key,
      "generation" => lease.generation,
      "writer_stopped" => true,
      "receipt" => "verified-fixture"
    }
  end
end
