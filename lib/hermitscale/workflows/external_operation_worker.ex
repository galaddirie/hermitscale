defmodule Hermitscale.Workflows.ExternalOperationWorker do
  @moduledoc "Bounded reconciliation of durable external intent and native graph continuation."
  use Oban.Worker,
    queue: :workflow_operations,
    max_attempts: 20,
    unique: [
      period: 60,
      fields: [:args],
      keys: [:operation_id, :run_id, :continuation_key],
      states: :incomplete
    ]

  alias Hermitscale.Workflows.ExternalOperations

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"operation_id" => id}}) do
    case ExternalOperations.reconcile(id) do
      {:ok, :waiting} -> {:snooze, 5}
      {:ok, :complete} -> {:ok, :complete}
      {:error, _reason} = error -> error
    end
  end

  def perform(%Oban.Job{args: %{"run_id" => id}}) do
    case ExternalOperations.advance(id) do
      {:ok, _run} -> {:ok, :advanced}
      {:error, _reason} = error -> error
    end
  end
end
