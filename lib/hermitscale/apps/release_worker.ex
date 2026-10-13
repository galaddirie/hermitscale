defmodule Hermitscale.Apps.ReleaseWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :apps,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:args, :queue],
      keys: [:deployment_id],
      states: :incomplete
    ]

  @impl true
  def perform(%Oban.Job{args: %{"deployment_id" => id}}) do
    case Hermitscale.Apps.reconcile_deployment(id) do
      {:ok, deployment} ->
        {:ok, deployment.id}

      {:error, reason}
      when reason in [
             :not_found,
             :forbidden,
             :execution_actor_ineligible,
             :active_deployment_changed,
             :configuration_changed,
             :remote_release_conflict
           ] ->
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
