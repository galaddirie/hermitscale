defmodule Hermitscale.Workspaces.Publication do
  @moduledoc "An ordinary Git commit and push in the admitted coding workspace."
  alias Hermitscale.Workspaces.{SpriteAccess, SpriteSDK}
  @path Path.expand("../../../priv/workspace_launchers/publication.py", __DIR__)
  @external_resource @path
  @script File.read!(@path)

  def publish(workspace, _lease, %{
        repository: repository,
        branch: branch,
        message: message,
        credential: %{value: credential}
      })
      when is_binary(repository) and is_binary(branch) and is_binary(message) and
             is_binary(credential) do
    with true <- Regex.match?(~r/\A(?:github:)?[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, repository),
         true <- byte_size(branch) in 1..200 and byte_size(message) in 1..4096,
         {:ok, sprite} <- SpriteAccess.sprite(workspace),
         {:ok, %{exit_code: 0, output: output}} <-
           SpriteSDK.capture(sprite, "sudo", ["-n", "python3", "-I", "-c", @script],
             stdin:
               Jason.encode!(%{
                 repository: repository,
                 branch: branch,
                 message: message,
                 credential: credential
               }),
             timeout: 120_000,
             output_limit: 4096
           ),
         {:ok, result} <- Jason.decode(output) do
      {:ok,
       %{
         repository: result["repository"],
         branch: result["branch"],
         commit_sha: result["commit_sha"]
       }}
    else
      false -> {:error, :invalid_publication}
      {:ok, %{exit_code: _code}} -> {:error, :publication_failed}
      {:error, _reason} = error -> error
    end
  end
end
