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
      {:get_sprite, :get, []},
      {:execute, :execute, ["sh", ["-c", "exit 7"], [env: [{"COLOR", "blue"}]]]},
      {:spawn, :spawn, ["sh", ["-c", "sleep 1"], [tty: true]]},
      {:list_sessions, :list_sessions, []},
      {:kill_session, :kill_session, ["session_123", [signal: "SIGTERM"]]},
      {:read_file, :read_file, ["/tmp/example"]},
      {:write_file, :write_file, ["/tmp/example", <<0, 255>>, [mode: "0600"]]},
      {:list_files, :list_files, ["/tmp"]},
      {:delete_file, :delete_file, ["/tmp/example", [recursive: true]]},
      {:list_checkpoints, :list_checkpoints, []},
      {:create_checkpoint, :create_checkpoint, [[comment: "Before changes"]]},
      {:restore_checkpoint, :restore_checkpoint, ["v1"]},
      {:list_services, :list_services, []},
      {:get_service, :get_service, ["web"]},
      {:put_service, :put_service, ["web", %{"cmd" => "server", "http_port" => 4000}]},
      {:delete_service, :delete_service, ["web"]},
      {:update_url_settings, :update_url_settings, [%{"auth" => "public"}]},
      {:get_network_policy, :get_network_policy, []},
      {:put_network_policy, :put_network_policy,
       [[%{"include" => "defaults"}, %{"domain" => "*", "action" => "deny"}]]}
    ]
  end
end
