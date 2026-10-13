defmodule Hermitscale.Agents.PublicationWorker do
  @moduledoc "Bounded branch effect reconciliation under the admitted actor."
  use Oban.Worker,
    queue: :publications,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:publication_id],
      states: :incomplete
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"publication_id" => id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    with {:ok, identity} <- Hermitscale.Agents.Publications.identity(id),
         {:ok, scope} <- Hermitscale.Authorization.execution_scope(identity),
         {:ok, pub} <- Hermitscale.Agents.Publications.reconcile(scope, id) do
      case pub.status do
        :succeeded -> {:ok, pub.result}
        :failed -> {:cancel, pub.error}
        _pending when attempt >= max_attempts -> cleanup(id, "reconciliation_attempts_exhausted")
        _pending -> {:error, :publication_uncertain}
      end
    else
      {:error, reason} when reason in [:execution_actor_ineligible, :forbidden] ->
        cleanup(id, Atom.to_string(reason))

      {:error, :not_found} ->
        {:cancel, :not_found}

      {:error, reason} when attempt >= max_attempts ->
        cleanup(id, "reconciliation_attempts_exhausted:" <> inspect(reason))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup(id, reason) do
    case Hermitscale.Agents.Publications.terminate(id, reason) do
      {:ok, %{status: :succeeded, result: result}} -> {:ok, result}
      {:ok, _retained} -> {:cancel, reason}
      {:error, :not_found} -> {:cancel, :not_found}
      {:error, pending} -> {:error, pending}
    end
  end
end
