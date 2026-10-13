defmodule Hermitscale.Reviews do
  @moduledoc "Action-bound review decisions; deciding never executes the approved effect."
  import Ecto.Query
  alias Hermitscale.{Authorization, Repo}
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Reviews.Review

  def request(scope, attrs) do
    with :ok <- permission(scope, ["reviews:request", "agents:run", "apps:deploy"]),
         attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end),
         attrs =
           if(is_map(attrs["target"]),
             do: Map.update!(attrs, "target", &(Jason.encode!(&1) |> Jason.decode!())),
             else: attrs
           ),
         :ok <- validate_target(scope, attrs) do
      ttl = Map.get(attrs, "expiry_seconds", 3600)

      if is_integer(ttl) and ttl in 1..86400 do
        attrs = Map.put_new(attrs, "eligible_approver_ids", [scope.user.id])

        changeset =
          Review.changeset(
            %Review{
              org_id: Scope.organization_id!(scope),
              requested_by_user_id: scope.user.id,
              expires_at: DateTime.add(DateTime.utc_now(:second), ttl)
            },
            attrs
          )

        with {:ok, _} <-
               Repo.insert(changeset,
                 on_conflict: :nothing,
                 conflict_target: [:org_id, :operation_key]
               ),
             {:ok, review} <- get_by_key(scope, attrs["operation_key"]) do
          candidate = Ecto.Changeset.apply_changes(changeset)

          if Map.take(candidate, [
               :action,
               :target_digest,
               :target,
               :policy_revision,
               :eligible_approver_ids
             ]) ==
               Map.take(review, [
                 :action,
                 :target_digest,
                 :target,
                 :policy_revision,
                 :eligible_approver_ids
               ]),
             do: {:ok, review},
             else: {:error, :review_key_conflict}
        end
      else
        {:error, :invalid_review_expiry}
      end
    end
  end

  def get(scope, id) do
    with :ok <- permission(scope, ["reviews:read", "agents:read", "apps:read"]),
         {:ok, id} <- uuid(id) do
      org = Scope.organization_id!(scope)
      actor = scope.user.id

      case Repo.one(
             from r in Review,
               where:
                 r.id == ^id and r.org_id == ^org and
                   (r.requested_by_user_id == ^actor or ^actor in r.eligible_approver_ids)
           ) do
        nil -> {:error, :not_found}
        review -> {:ok, review}
      end
    end
  end

  def list(scope) do
    with :ok <- permission(scope, ["reviews:read", "agents:read", "apps:read"]) do
      org = Scope.organization_id!(scope)
      actor = scope.user.id

      Repo.all(
        from r in Review,
          where:
            r.org_id == ^org and
              (r.requested_by_user_id == ^actor or ^actor in r.eligible_approver_ids),
          order_by: [desc: r.inserted_at],
          limit: 100
      )
    end
  end

  def subscribe(scope, id) do
    with {:ok, review} <- get(scope, id),
         do: Phoenix.PubSub.subscribe(Hermitscale.PubSub, "reviews:" <> review.id)
  end

  def decide(scope, id, decision) when decision in [:approved, :rejected] do
    with {:ok, current} <- current_scope(scope, "reviews:decide"),
         {:ok, review} <- get(current, id) do
      result =
        Repo.transaction(fn ->
          review = Repo.one!(from r in Review, where: r.id == ^review.id, lock: "FOR UPDATE")

          cond do
            DateTime.compare(review.expires_at, DateTime.utc_now(:second)) != :gt ->
              Repo.rollback(:review_expired)

            current.user.id not in review.eligible_approver_ids ->
              Repo.rollback(:ineligible_approver)

            review.status == decision and review.decided_by_user_id == current.user.id ->
              review

            review.status != :requested ->
              Repo.rollback(:review_already_decided)

            true ->
              review
              |> Ecto.Changeset.change(
                status: decision,
                decided_by_user_id: current.user.id,
                decided_at: DateTime.utc_now(:second)
              )
              |> Repo.update!()
          end
        end)

      case result do
        {:ok, updated} ->
          Phoenix.PubSub.broadcast(
            Hermitscale.PubSub,
            "reviews:" <> updated.id,
            {:review_updated, updated.id}
          )

          Enum.each(
            ~w(review publication_review deployment_review support_reply_review),
            &Hermitscale.Workflows.ExternalOperations.notify(&1, updated.id)
          )

          {:ok, updated}

        {:error, _reason} = error ->
          error
      end
    end
  end

  def decide(_scope, _id, _decision), do: {:error, :invalid_decision}

  def authorize_decision(scope, id, action, digest, policy_revision) do
    with {:ok, review} <- get(scope, id),
         true <- review.status == :approved,
         true <-
           review.action == action and review.target_digest == digest and
             review.policy_revision == policy_revision,
         :gt <- DateTime.compare(review.expires_at, DateTime.utc_now(:second)),
         {:ok, _approver} <-
           Authorization.execution_scope(%Hermitscale.Integrations.ExecutionContext{
             organization_id: review.org_id,
             actor_user_id: review.decided_by_user_id,
             required_permissions: ["reviews:decide"]
           }) do
      :ok
    else
      false -> {:error, :review_mismatch_or_not_approved}
      :eq -> {:error, :review_expired}
      :lt -> {:error, :review_expired}
      {:error, _reason} = error -> error
    end
  end

  defp get_by_key(scope, key) do
    case Repo.get_by(Review, org_id: Scope.organization_id!(scope), operation_key: key) do
      nil -> {:error, :not_found}
      r -> {:ok, r}
    end
  end

  defp permission(scope, permissions),
    do:
      if(Enum.any?(permissions, &(Authorization.authorize(scope, &1) == :ok)),
        do: :ok,
        else: {:error, :forbidden}
      )

  defp current_scope(scope, permission) do
    with :ok <- Authorization.authorize(scope, permission),
         do: scope |> Scope.execution_context([permission]) |> Authorization.execution_scope()
  end

  def get_review(scope, id), do: get(scope, id)

  defp validate_target(_scope, %{"target" => target}) when target == %{}, do: :ok

  defp validate_target(
         scope,
         %{"target" => target, "action" => action, "target_digest" => expected} = attrs
       )
       when is_map(target) do
    digest =
      case action do
        "agents.publish_branch" ->
          Hermitscale.Agents.Publications.target_digest(scope, target["session_id"], target)

        "apps.deploy" ->
          with {:ok, environment} <-
                 Hermitscale.Apps.get_environment(scope, target["environment_id"]) do
            Hermitscale.Apps.deployment_target_digest(
              scope,
              environment.app_id,
              Map.put_new(target, "operation_key", attrs["operation_key"])
            )
          end

        "apps.publish" ->
          Hermitscale.Apps.publication_target_digest(
            scope,
            target["environment_id"],
            target["public"]
          )

        "apps.restore_data" ->
          Hermitscale.Apps.restore_target_digest(
            scope,
            target["environment_id"],
            target["backup_id"]
          )

        "support.reply" ->
          {:ok,
           Hermitscale.Support.reply_digest(
             target["case_id"],
             target["body"],
             target["outcome"],
             target["deployment_id"]
           )}

        _other ->
          {:ok, Hermitscale.Agents.Protocol.payload_digest(target)}
      end

    case digest do
      {:ok, ^expected} -> :ok
      {:ok, _different} -> {:error, :review_target_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_target(_scope, _attrs), do: :ok

  defp uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end
end
