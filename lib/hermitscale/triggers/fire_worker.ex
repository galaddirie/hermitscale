defmodule Hermitscale.Triggers.FireWorker do
  @moduledoc """
  Oban worker that fires one schedule-trigger occurrence.

  Job uniqueness on `{trigger_id, scheduled_for}` prevents duplicate enqueues
  when scheduler ticks race across nodes; the dispatcher's idempotency key on
  the same pair prevents repeating completed occurrences across job retries.
  An unresolved reservation remains retryable until it is reconciled.
  """

  use Oban.Worker,
    queue: :triggers,
    max_attempts: 3,
    unique: [period: 3_600, keys: [:trigger_id, :scheduled_for]]

  alias Hermitscale.Repo
  alias Hermitscale.Triggers
  alias Hermitscale.Triggers.{Dispatcher, Trigger}
  alias Hermitscale.Workflows.Run

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"trigger_id" => trigger_id, "scheduled_for" => scheduled_for}})
      when is_binary(trigger_id) and trigger_id != "" and is_binary(scheduled_for) do
    case DateTime.from_iso8601(scheduled_for) do
      {:ok, scheduled_at, _offset} -> fire_occurrence(trigger_id, scheduled_for, scheduled_at)
      {:error, _reason} -> {:cancel, :invalid_scheduled_for}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  defp fire_occurrence(trigger_id, scheduled_for, scheduled_at) do
    case Repo.get(Trigger, trigger_id) do
      %Trigger{mode: :schedule, status: :enabled} = trigger ->
        fire(trigger, scheduled_for, scheduled_at)

      %Trigger{mode: :schedule} ->
        {:cancel, :disabled}

      %Trigger{} ->
        {:cancel, :invalid_trigger_mode}

      nil ->
        {:cancel, :deleted}
    end
  end

  defp fire(trigger, scheduled_for, scheduled_at) do
    module = Triggers.catalog_module!(trigger)
    payload = module.build_payload(Triggers.cast_params!(trigger), scheduled_at)

    key = "schedule:#{trigger.id}:#{scheduled_for}"

    case Dispatcher.fire(trigger, payload, idempotency_key: key) do
      {:ok, %Run{}} = success ->
        success

      {:ok, :deduped} = success ->
        success

      {:error, :rejected} ->
        {:ok, :rejected}

      {:error, reason} when reason in [:disabled, :execution_actor_ineligible] ->
        {:cancel, reason}

      {:error, {:connection_not_ready, _node, reason}}
      when reason in [:needs_reauthorization, :account_not_found, :insufficient_scopes] ->
        {:cancel, reason}

      {:error, {:start_run, reason}} ->
        {:error, reason}

      {:error, _reason} = error ->
        error
    end
  end
end
