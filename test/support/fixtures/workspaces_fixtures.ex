defmodule Hermitscale.WorkspacesFixtures do
  @moduledoc false

  def workspace_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{name: "Development", description: "Shared organization workspace"})
  end

  def workspace_fixture(scope, attrs \\ %{}) do
    {:ok, workspace} = Hermitscale.Workspaces.create_workspace(scope, workspace_attrs(attrs))
    workspace
  end

  def workspace_operations do
    [
      {:execute, ["sh", ["-c", "exit 7"], [env: %{"COLOR" => "blue"}]]},
      {:spawn, ["sh", ["-c", "sleep 1"], [tty: true]]},
      {:list_sessions, []},
      {:kill_session, ["session_123", [signal: "SIGTERM"]]},
      {:attach_session, ["session_123", [tty: true]]},
      {:read_file, ["/tmp/example", [range: "bytes=0-3"]]},
      {:write_file, ["/tmp/example", <<0, 255>>, [mode: "0600"]]},
      {:list_files, ["/tmp", [recursive: true]]},
      {:delete_file, ["/tmp/example", [recursive: true]]},
      {:list_checkpoints, [[limit: 5]]},
      {:create_checkpoint, [[comment: "Before changes"]]},
      {:restore_checkpoint, ["checkpoint_123"]},
      {:list_services, []},
      {:get_service, ["web"]},
      {:put_service, ["web", %{"cmd" => "server", "http_port" => 4000}]},
      {:delete_service, ["web"]},
      {:update_url_settings, [%{"auth" => "public"}]}
    ]
  end

  def membership_response(user_id, org_id) do
    {:ok,
     %{
       "data" => [
         Hermitscale.WorkOS.ClientFixtures.membership_fixture("membership_workspaces", %{
           "user_id" => user_id,
           "organization_id" => org_id
         })
       ]
     }}
  end
end
