defmodule Hermitscale.Triggers.WebhookDeliveryWorker do
  @moduledoc "Dispatches an authenticated retained provider event through the workflow trigger dispatcher."
  use Oban.Worker,
    queue: :triggers,
    max_attempts: 5,
    unique: [
      period: 60,
      fields: [:args],
      keys: [:delivery_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => id}}) when is_binary(id),
    do: Hermitscale.Triggers.Webhooks.deliver(id)

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}
end
