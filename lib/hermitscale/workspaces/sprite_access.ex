defmodule Hermitscale.Workspaces.SpriteAccess do
  @moduledoc "Private retained Sprite execution and bounded, symlink-confined VFS access."
  alias Hermitscale.Workspaces.{ConfinedVFSClient, Lease, SpriteSDK, SpritesManagement, Workspace}
  @root "/workspace"

  def qualification do
    %{
      status: :implemented,
      shell: Jido.Shell.version(),
      vfs: Application.spec(:jido_vfs, :vsn) |> to_string(),
      configured: match?({:ok, _token}, SpritesManagement.token())
    }
  end

  def attach_shell(%Workspace{} = workspace, %Lease{} = lease) do
    with {:ok, token} <- SpritesManagement.token(),
         {:ok, sprite} <- sprite(workspace),
         :ok <- Hermitscale.Workspaces.Foundation.prepare(sprite) do
      Jido.Shell.ShellSession.start(workspace.id,
        session_id: Ecto.UUID.generate(),
        cwd: @root,
        backend: {Jido.Shell.Backend.Sprite, shell_config(workspace, lease, token)}
      )
    end
  end

  def execute_command(%Workspace{} = workspace, %Lease{} = lease, command) do
    with {:ok, session_id} <- attach_shell(workspace, lease) do
      try do
        with {:ok, :subscribed} <- Jido.Shell.ShellSessionServer.subscribe(session_id, self()),
             {:ok, :accepted} <-
               Jido.Shell.ShellSessionServer.run_command(
                 session_id,
                 bounded_command(command, lease),
                 timeout: remaining_ms(lease) + 3_000,
                 output_limit: 65_536
               ) do
          await_command(
            session_id,
            "",
            System.monotonic_time(:millisecond) + remaining_ms(lease) + 4_000
          )
        else
          {:error, _error} -> {:error, :sprite_transport_unavailable}
        end
      after
        Jido.Shell.ShellSession.stop(session_id)
      end
    end
  end

  def read_file(workspace, _lease, path) do
    with {:ok, fs} <- filesystem(workspace) do
      case Jido.VFS.read(fs, path) do
        {:ok, data} -> {:ok, data}
        {:error, %Jido.VFS.Errors.FileNotFound{}} -> {:error, :file_not_found}
        {:error, _error} -> {:error, :file_access_rejected}
      end
    end
  end

  def write_file(workspace, _lease, path, content) do
    with {:ok, fs} <- filesystem(workspace) do
      case Jido.VFS.write(fs, path, content) do
        :ok -> :ok
        {:error, _error} -> {:error, :file_access_rejected}
      end
    end
  end

  def shell_config(workspace, lease, token) do
    %{
      sprite_name: workspace.sprite_name,
      token: token,
      create: false,
      cwd: @root,
      sprites_module: SpriteSDK,
      env: %{},
      meta: %{
        workspace_id: workspace.id,
        operation_key: lease.operation_key,
        generation: lease.generation
      }
    }
  end

  def vfs_options(workspace, token),
    do: [
      sprite_name: workspace.sprite_name,
      token: token,
      root: @root,
      encoding: :base64,
      create_on_demand: false,
      probe_commands: false,
      client: ConfinedVFSClient
    ]

  def sprite(workspace) do
    with {:ok, token} <- SpritesManagement.token() do
      config = Application.get_env(:hermitscale, SpritesManagement, [])

      client =
        SpriteSDK.api().new(token,
          base_url: Keyword.get(config, :base_url, "https://api.sprites.dev")
        )

      {:ok, SpriteSDK.api().sprite(client, workspace.sprite_name)}
    end
  end

  defp filesystem(workspace) do
    with {:ok, token} <- SpritesManagement.token(),
         {:ok, sprite} <- sprite(workspace),
         :ok <- Hermitscale.Workspaces.Foundation.prepare(sprite) do
      {:ok, Jido.VFS.Adapter.Sprite.configure([sprite: sprite] ++ vfs_options(workspace, token))}
    end
  end

  defp bounded_command(command, lease),
    do:
      "sudo -n /opt/hermitscale/bin/sandbox-launch coder /usr/bin/timeout --signal=TERM --kill-after=2s #{max(div(remaining_ms(lease), 1000), 1)}s bash -lc " <>
        shell_quote(command)

  def shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp remaining_ms(lease),
    do: max(DateTime.diff(lease.deadline, DateTime.utc_now(), :millisecond), 1)

  defp await_command(id, output, deadline) do
    receive do
      {:jido_shell_session, ^id, {:output, chunk}} ->
        await_command(id, output <> chunk, deadline)

      {:jido_shell_session, ^id, {:output_stderr, chunk}} ->
        await_command(id, output <> chunk, deadline)

      {:jido_shell_session, ^id, :command_done} ->
        {:ok, %{exit_code: 0, output: output}}

      {:jido_shell_session, ^id,
       {:error, %Jido.Shell.Error{code: {:command, :exit_code}, context: %{code: code}}}} ->
        {:ok, %{exit_code: code, output: output}}

      {:jido_shell_session, ^id, {:error, _error}} ->
        {:error, :sprite_command_failed}

      {:jido_shell_session, ^id, {:command_started, _line}} ->
        await_command(id, output, deadline)

      {:jido_shell_session, ^id, {:cwd_changed, _cwd}} ->
        await_command(id, output, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Jido.Shell.ShellSessionServer.cancel(id)
        {:error, :sprite_command_timeout}
    end
  end
end
