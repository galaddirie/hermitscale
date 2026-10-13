defmodule Hermitscale.Agents.Approvals do
  @moduledoc "Internal native permission decisions for the current turn's executing actor."
  import Ecto.Query
  alias Ecto.Changeset
  alias Hermitscale.{Agents, Authorization, Repo}
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Agents.{Approval, Protocol, Turn}

  def request(scope, turn_id, attrs) do
    with {:ok, scope} <- current_scope(scope),
         {:ok, turn} <- owned_turn(scope, turn_id) do
      attrs =
        attrs
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.take(~w(action target_digest policy_revision))
        |> Map.put_new("policy_revision", 1)

      identity = Protocol.payload_digest([turn.id, attrs])
      {:ok, id} = Ecto.UUID.load(binary_part(Base.decode16!(identity, case: :lower), 0, 16))

      changeset =
        Approval.changeset(
          %Approval{id: id, org_id: turn.org_id, turn_id: turn.id, expires_at: turn.deadline},
          attrs
        )

      case {changeset.valid?, retained_request(changeset, turn, attrs)} do
        {false, nil} ->
          {:error, changeset}

        {true, %Approval{} = approval} ->
          {:ok, approval}

        {true, nil} ->
          with {:ok, _approval} <- Repo.insert(changeset, on_conflict: :nothing),
               {:ok, approval} <- get(scope, id) do
            {:ok, approval}
          end
      end
    end
  end

  def get(scope, id) do
    with {:ok, scope} <- current_scope(scope),
         {:ok, id} <- uuid(id) do
      org = Scope.organization_id!(scope)

      case Repo.get_by(Approval, id: id, org_id: org) do
        nil ->
          {:error, :not_found}

        approval ->
          with {:ok, _turn} <- owned_turn(scope, approval.turn_id), do: {:ok, approval}
      end
    end
  end

  def decide(scope, id, decision) when decision in [:approved, :rejected] do
    with {:ok, scope} <- current_scope(scope),
         {:ok, approval} <- get(scope, id) do
      Repo.transaction(fn ->
        approval = Repo.one!(from a in Approval, where: a.id == ^approval.id, lock: "FOR UPDATE")
        turn = Repo.one!(from t in Turn, where: t.id == ^approval.turn_id, lock: "FOR UPDATE")

        cond do
          DateTime.compare(approval.expires_at, DateTime.utc_now(:second)) != :gt ->
            Repo.rollback(:approval_expired)

          turn.status != :waiting_for_approval or turn.approval_id != approval.id ->
            Repo.rollback(:stale_approval)

          approval.status == decision and approval.decided_by_user_id == scope.user.id ->
            approval

          approval.status != :pending ->
            Repo.rollback(:approval_already_decided)

          true ->
            approval
            |> Changeset.change(status: decision, decided_by_user_id: scope.user.id)
            |> Repo.update!()
        end
      end)
    end
  end

  def decide(_scope, _id, _decision), do: {:error, :invalid_decision}

  def authorize_decision(scope, id, action, digest, policy_revision) do
    with {:ok, approval} <- get(scope, id),
         true <-
           approval.status == :approved and approval.action == action and
             approval.target_digest == digest and approval.policy_revision == policy_revision,
         :gt <- DateTime.compare(approval.expires_at, DateTime.utc_now(:second)) do
      :ok
    else
      false -> {:error, :approval_mismatch_or_not_approved}
      :eq -> {:error, :approval_expired}
      :lt -> {:error, :approval_expired}
      {:error, _reason} = error -> error
    end
  end

  defp retained_request(%Changeset{valid?: false}, _turn, _attrs), do: nil
  defp retained_request(_changeset, %Turn{approval_id: nil}, _attrs), do: nil

  defp retained_request(_changeset, turn, attrs) do
    Repo.get_by(Approval,
      id: turn.approval_id,
      turn_id: turn.id,
      org_id: turn.org_id,
      action: attrs["action"],
      target_digest: attrs["target_digest"],
      policy_revision: attrs["policy_revision"]
    )
  end

  defp owned_turn(scope, id) do
    with {:ok, turn} <- Agents.get_turn(scope, id),
         true <- turn.execution_actor_user_id == scope.user.id do
      {:ok, turn}
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp current_scope(scope) do
    with :ok <- Authorization.authorize(scope, "agents:run") do
      scope
      |> Scope.execution_context(["agents:read", "agents:run"])
      |> Authorization.execution_scope()
    end
  end

  defp uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end
end
