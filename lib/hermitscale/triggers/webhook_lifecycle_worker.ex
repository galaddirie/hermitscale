defmodule Hermitscale.Triggers.WebhookLifecycleWorker do
  @moduledoc "Reconciles a durable subscription's latest desired state with its provider."
  use Oban.Worker,
    queue: :triggers,
    max_attempts: 8,
    unique: [
      period: 60,
      fields: [:args],
      keys: [:subscription_id, :generation, :enabled],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Hermitscale.Triggers.Webhooks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => id}}) when is_binary(id) do
    case Webhooks.reconcile(id) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        case Webhooks.terminal?(reason) do
          true -> {:cancel, reason}
          false -> {:error, reason}
        end
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}
end
