defmodule Hermitscale.Workspaces.Publication do
  @moduledoc "An operation-bound explicit Git manifest commit and reconciled branch push."
  alias Hermitscale.Workspaces.{SpriteAccess, SpriteSDK}

  @script_path Path.expand("../../../priv/workspace_launchers/publication.py", __DIR__)
  @external_resource @script_path
  @script File.read!(@script_path)

  def publish(workspace, lease, attrs) do
    %{value: credential} = Map.fetch!(attrs, :credential)

    attrs =
      attrs
      |> Map.put(:credential, credential)
      |> Map.put(:lease_id, lease.id)
      |> Map.put(:deadline, DateTime.to_iso8601(lease.deadline))

    with {:ok, sprite} <- SpriteAccess.sprite(workspace),
         {:ok, %{exit_code: 0, output: output}} <-
           SpriteSDK.capture(
             sprite,
             "sudo",
             ["-n", "python3", "-I", "-c", @script],
             stdin: Jason.encode!(attrs),
             timeout: 300_000,
             output_limit: 8192
           ),
         {:ok, result} <- Jason.decode(output) do
      {:ok, result}
    else
      {:ok, %{exit_code: 81}} ->
        {:error, :publication_key_conflict}

      {:ok, %{exit_code: 82}} ->
        {:error, :source_revision_changed}

      {:ok, %{exit_code: 83}} ->
        {:error, :branch_conflict}

      {:ok, %{exit_code: 84, output: output}} ->
        case Jason.decode(output) do
          {:ok, %{"local_commit" => _sha} = receipt} ->
            {:error, {:publication_uncertain, receipt}}

          {:error, _reason} ->
            {:error, :publication_uncertain}
        end

      {:ok, %{exit_code: 86}} ->
        {:error, :candidate_changed}

      {:ok, %{exit_code: 87}} ->
        {:error, :manifest_not_in_candidate}

      {:ok, %{exit_code: 88}} ->
        {:error, :publication_deadline}

      {:ok, %{exit_code: 80}} ->
        {:error, :publication_failed}

      {:ok, %{exit_code: _status}} ->
        {:error, :publication_uncertain}

      {:error, _reason} = error ->
        error
    end
  end
end
