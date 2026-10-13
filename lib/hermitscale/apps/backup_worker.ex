defmodule Hermitscale.Apps.BackupWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :apps,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:args, :queue],
      keys: [:environment_id],
      states: :incomplete
    ]

  @impl true
  def perform(%Oban.Job{args: args}) do
    case Hermitscale.Apps.perform_backup(args) do
      {:ok, backup} ->
        {:ok, backup.id}

      {:error, reason} when reason in [:not_found, :forbidden, :execution_actor_ineligible] ->
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
