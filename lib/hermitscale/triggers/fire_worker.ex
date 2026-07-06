defmodule Hermitscale.Triggers.FireWorker do
  @moduledoc """
  Oban worker that fires one schedule-trigger occurrence.

  Job uniqueness on `{trigger_id, scheduled_for}` prevents duplicate enqueues
  when scheduler ticks race across nodes; the dispatcher's idempotency key on
  the same pair makes execution effectively-once even across job retries.
  """

  use Oban.Worker,
    queue: :triggers,
    max_attempts: 3,
    unique: [period: 3_600, keys: [:trigger_id, :scheduled_for]]

  alias Hermitscale.Repo
  alias Hermitscale.Triggers
  alias Hermitscale.Triggers.{Dispatcher, Trigger}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"trigger_id" => trigger_id, "scheduled_for" => scheduled_for}}) do
    case Repo.get(Trigger, trigger_id) do
      %Trigger{mode: :schedule, status: :enabled} = trigger ->
        fire(trigger, scheduled_for)

      _deleted_or_not_enabled ->
        :ok
    end
  end

  defp fire(trigger, scheduled_for) do
    {:ok, scheduled_at, _offset} = DateTime.from_iso8601(scheduled_for)

    payload =
      trigger
      |> Triggers.catalog_module!()
      |> apply(:build_payload, [Triggers.cast_params!(trigger), scheduled_at])

    key = "schedule:#{trigger.id}:#{scheduled_for}"

    case Dispatcher.fire(trigger, payload, idempotency_key: key) do
      {:ok, _run_or_deduped} -> :ok
      {:error, :disabled} -> :ok
      {:error, :rejected} -> :ok
      {:error, {:start_run, reason}} -> {:error, reason}
    end
  end
end
