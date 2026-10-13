defmodule Hermitscale.Apps.RecoveryWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :apps,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:args, :queue],
      keys: [:recovery_id],
      states: :incomplete
    ]

  @impl true
  def perform(%Oban.Job{args: %{"recovery_id" => id}}) do
    case Hermitscale.Apps.reconcile_recovery(id) do
      {:ok, recovery} ->
        {:ok, recovery.id}

      {:error, reason}
      when reason in [
             :not_found,
             :forbidden,
             :execution_actor_ineligible,
             :active_deployment_changed
           ] ->
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
