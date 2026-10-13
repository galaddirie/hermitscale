defmodule Hermitscale.Workspaces.SpriteAccess do
  @moduledoc "Bounded Sprite commands and confined workspace files."
  alias Hermitscale.Workspaces.{Files, SpriteSDK, SpritesManagement}

  def execute_command(workspace, lease, command) do
    with {:ok, sprite} <- sprite(workspace),
         :ok <- Hermitscale.Workspaces.Foundation.prepare(sprite) do
      milliseconds = max(DateTime.diff(lease.deadline, DateTime.utc_now(), :millisecond), 1)

      SpriteSDK.capture(
        sprite,
        "sudo",
        [
          "-n",
          "/opt/hermitscale/bin/sandbox-launch",
          "coder",
          "/usr/bin/timeout",
          "--signal=TERM",
          "--kill-after=2s",
          "#{max(div(milliseconds, 1000), 1)}s",
          "bash",
          "-lc",
          command
        ],
        cwd: "/workspace",
        timeout: milliseconds + 3_000,
        output_limit: 65_536
      )
    end
  end

  def publish_branch(workspace, lease, attributes),
    do: Hermitscale.Workspaces.Publication.publish(workspace, lease, attributes)

  def read_file(workspace, _lease, path), do: Files.read(workspace, path)
  def write_file(workspace, _lease, path, content), do: Files.write(workspace, path, content)

  def read_result(workspace, _lease),
    do: Files.read(workspace, ".hermitscale/result.json", 65_536)

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
end
