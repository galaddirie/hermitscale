defmodule Hermitscale.Agents.ReconcileWorker do
  @moduledoc "Durable bounded dispatch with current authority; a retry reconciles the same turn."
  use Oban.Worker,
    queue: :agents,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args], keys: [:turn_id], states: :incomplete]

  alias Hermitscale.{Agents, Authorization}
  alias Hermitscale.Agents.{SessionAgent, Turn}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"turn_id" => id}, attempt: attempt, max_attempts: max_attempts}) do
    with {:ok, identity} <- Agents.execution_identity(id),
         {:ok, scope} <- Authorization.execution_scope(identity),
         {:ok, turn} <- Agents.get_turn(scope, id) do
      cond do
        Turn.terminal?(turn) -> Agents.reconcile_turn(scope, id)
        true -> reconcile(scope, turn)
      end
    else
      {:error, :execution_actor_ineligible} ->
        case Agents.terminate_turn(id, "execution_actor_ineligible") do
          {:ok, _turn} -> {:cancel, :execution_actor_ineligible}
          {:error, :not_found} -> {:cancel, :not_found}
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:cancel, :not_found}

      {:error, :forbidden} ->
        {:cancel, :forbidden}

      {:error, reason}
      when reason in [:unavailable, :rate_limited, :invalid_response] and attempt >= max_attempts ->
        case Agents.interrupt_undispatched_turn(id, "authority_unavailable") do
          {:ok, _turn} -> {:cancel, reason}
          {:error, pending_reason} -> {:cancel, pending_reason}
        end

      {:error, reason} ->
        if attempt >= max_attempts do
          case Agents.terminate_turn(id, "reconciliation_failed:" <> inspect(reason)) do
            {:ok, _turn} -> {:cancel, reason}
            {:error, pending} -> {:error, pending}
          end
        else
          {:error, reason}
        end
    end
  end

  defp reconcile(scope, turn) do
    # Check serial admission before starting an in-memory coordinator. Product state
    # remains authoritative even if the agent or this job dies after the commit.
    case Agents.pending_before?(scope, turn.id) do
      {:ok, false} ->
        case SessionAgent.reconcile(scope, turn) do
          {:ok, %{status: status}}
          when status in ["running", "provisioning", "waiting_for_approval", "waiting_for_input"] ->
            {:snooze, 2}

          {:ok, projection} ->
            {:ok, projection}

          {:error, :waiting_for_previous_turn} ->
            {:snooze, 10}

          {:error, :reconciliation_required} ->
            {:cancel, :reconciliation_required}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, true} ->
        {:snooze, 10}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
