defmodule Hermitscale.Workflows.ExternalOperationAdapter do
  @moduledoc "Dispatches workflow intent exclusively through the owning public context."
  alias Hermitscale.{Agents, Apps, Reviews, Support}
  alias Hermitscale.Integrations.Deliveries

  @callback dispatch(Hermitscale.Accounts.Scope.t(), map()) ::
              {:waiting, map()} | {:complete, map()} | {:error, term()}
  @callback poll(Hermitscale.Accounts.Scope.t(), map()) ::
              {:waiting, map()} | {:complete, map()} | {:error, term()}

  def dispatch(scope, %{node_type: "agents.codex.run", request: request} = operation) do
    with {:ok, session} <- coding_session(scope, operation),
         {:ok, turn} <-
           Agents.submit_turn(
             scope,
             session.id,
             request
             |> Map.take(["instructions", "budget_cents", "timeout_seconds", "result_schema"])
             |> Map.put("operation_key", operation.id)
           ) do
      {:waiting,
       %{
         "kind" => "turn",
         "id" => turn.id,
         "session_id" => session.id,
         "workspace_id" => session.workspace_id
       }}
    end
  end

  def dispatch(scope, %{node_type: "agents.publish_branch", request: request} = operation) do
    case Map.has_key?(request, "review_id") do
      true ->
        request_publication(scope, operation, request)

      false ->
        with {:ok, digest} <-
               Hermitscale.Agents.Publications.target_digest(
                 scope,
                 request["session_id"],
                 request
               ),
             {:ok, review} <-
               Reviews.request(scope, %{
                 action: "agents.publish_branch",
                 target_digest: digest,
                 target: request,
                 policy_revision: request["policy_revision"],
                 operation_key: operation.id <> ":review"
               }) do
          {:waiting, %{"kind" => "publication_review", "id" => review.id}}
        end
    end
  end

  def dispatch(scope, %{node_type: "apps.preview.create", request: request} = operation) do
    with {:ok, preview} <-
           Apps.ensure_preview(scope, Map.fetch!(request, "app_id"), effect_attrs(operation)) do
      preview_result(preview)
    end
  end

  def dispatch(scope, %{node_type: "apps.deploy", request: request} = operation) do
    case Map.has_key?(request, "review_id") do
      true ->
        request_deployment(scope, operation, request)

      false ->
        with {:ok, digest} <-
               Apps.deployment_target_digest(
                 scope,
                 Map.fetch!(request, "app_id"),
                 effect_attrs(operation)
               ),
             {:ok, review} <-
               Reviews.request(scope, %{
                 action: "apps.deploy",
                 target_digest: digest,
                 target: request,
                 policy_revision: Map.get(request, "policy_revision", 1),
                 operation_key: operation.id <> ":review"
               }) do
          {:waiting, %{"kind" => "deployment_review", "id" => review.id}}
        end
    end
  end

  def dispatch(scope, %{node_type: "apps.logs.read", request: request}) do
    opts =
      request
      |> Map.take(["limit", "max_bytes", "wake", "environment_id"])
      |> Enum.map(fn {key, value} -> {log_option(key), value} end)

    with {:ok, logs} <- Apps.read_logs(scope, Map.fetch!(request, "app_id"), opts) do
      {:complete, %{"logs" => logs}}
    end
  end

  def dispatch(scope, %{node_type: "reviews.request"} = operation) do
    policy = operation.request["reviewer_policy"]

    attrs =
      effect_attrs(operation)
      |> Map.put("expiry_seconds", operation.request["timeout_seconds"])

    attrs =
      case Map.fetch(policy, "eligible_approver_ids") do
        {:ok, ids} -> Map.put(attrs, "eligible_approver_ids", ids)
        :error -> attrs
      end

    with {:ok, review} <- Reviews.request(scope, attrs) do
      {:waiting, %{"kind" => "review", "id" => review.id}}
    end
  end

  def dispatch(scope, %{node_type: type} = operation)
      when type in ["github.pull_requests.create", "linear.comments.create"] do
    deliver(scope, operation)
  end

  def dispatch(scope, %{node_type: "support.investigate", request: request} = operation) do
    with {:ok, investigation} <-
           Support.investigate(
             scope,
             request["subscription_id"],
             request["ticket_id"],
             operation.id
           ),
         {:ok, turn} <-
           Agents.get_turn_by_operation(
             scope,
             investigation.session_id,
             "support-turn:" <> operation.id
           ) do
      {:waiting,
       %{
         "kind" => "support_investigation",
         "id" => investigation.id,
         "turn_id" => turn.id,
         "session_id" => investigation.session_id,
         "deployed_revision" => investigation.deployed_revision
       }}
    end
  end

  def dispatch(scope, %{node_type: "support.reply", request: request} = operation) do
    case Map.has_key?(request, "review_id") do
      true ->
        request_support_reply(scope, operation, request)

      false ->
        with {:ok, review} <-
               Reviews.request(scope, %{
                 operation_key: operation.id <> ":review",
                 action: "support.reply",
                 policy_revision: 1,
                 target_digest:
                   Support.reply_digest(
                     request["case_id"],
                     request["body"],
                     request["outcome"],
                     request["deployment_id"]
                   ),
                 target: request
               }) do
          {:waiting, %{"kind" => "support_reply_review", "id" => review.id}}
        end
    end
  end

  def poll(scope, %{resource: %{"kind" => "turn", "id" => id} = resource}) do
    with {:ok, turn} <- Agents.get_turn(scope, id) do
      case turn.status do
        :succeeded ->
          result = Map.merge(turn.result, Map.drop(resource, ["kind", "id"]))
          {:complete, Map.merge(result, %{"turn_id" => id, "outcome" => "succeeded"})}

        status when status in [:failed, :interrupted, :cancelled] ->
          {:error, %{"reason" => "agent_turn_#{status}", "details" => turn.error}}

        status
        when status in [
               :queued,
               :provisioning,
               :running,
               :waiting_for_input,
               :waiting_for_approval
             ] ->
          {:waiting, resource}
      end
    end
  end

  def poll(scope, %{resource: %{"kind" => "publication", "id" => id} = resource}) do
    with {:ok, publication} <- Agents.get_publication(scope, id) do
      case publication.status do
        :succeeded ->
          {:complete, Map.put(publication.result, "publication_id", publication.id)}

        status when status in [:failed, :cancelled] ->
          {:error, publication.error}

        status when status in [:queued, :running, :uncertain, :waiting_for_approval] ->
          {:waiting, resource}
      end
    end
  end

  def poll(
        scope,
        %{resource: %{"kind" => "publication_review", "id" => id} = resource} = operation
      ) do
    with {:ok, review} <- Reviews.get_review(scope, id) do
      case review.status do
        :approved ->
          request_publication(
            scope,
            operation,
            Map.put(operation.request, "review_id", review.id)
          )

        :rejected ->
          {:error, %{"reason" => "review_rejected", "review_id" => id}}

        :requested ->
          {:waiting, resource}
      end
    end
  end

  def poll(scope, %{resource: %{"kind" => "preview", "id" => id}}) do
    with {:ok, preview} <- Apps.get_preview(scope, id), do: preview_result(preview)
  end

  def poll(scope, %{resource: %{"kind" => "deployment", "id" => id} = resource}) do
    with {:ok, deployment} <- Apps.get_deployment(scope, id) do
      case deployment.status do
        status when status in ["active", "superseded", "rolled_back"] ->
          {:complete, Apps.result(deployment)}

        status when status in ["failed", "cancelled"] ->
          {:error, deployment.error}

        status
        when status in [
               "requested",
               "building",
               "releasing",
               "verifying",
               "activating",
               "queued",
               "waiting_for_approval",
               "maintenance"
             ] ->
          {:waiting, resource}
      end
    end
  end

  def poll(
        scope,
        %{resource: %{"kind" => "deployment_review", "id" => id} = resource} = operation
      ) do
    with {:ok, review} <- Reviews.get_review(scope, id) do
      case review.status do
        :approved ->
          request_deployment(scope, operation, Map.put(operation.request, "review_id", review.id))

        :rejected ->
          {:error, %{"reason" => "review_rejected", "review_id" => id}}

        :requested ->
          {:waiting, resource}
      end
    end
  end

  def poll(scope, %{resource: %{"kind" => "review", "id" => id} = resource}) do
    with {:ok, review} <- Reviews.get_review(scope, id) do
      case review.status do
        :approved ->
          {:complete,
           %{
             "review_id" => review.id,
             "decision" => "approved",
             "target_digest" => review.target_digest,
             "policy_revision" => review.policy_revision
           }}

        :rejected ->
          {:error, %{"reason" => "review_rejected", "review_id" => review.id}}

        :requested ->
          {:waiting, resource}
      end
    end
  end

  def poll(scope, %{resource: %{"kind" => "delivery"}} = operation), do: deliver(scope, operation)

  def poll(scope, %{
        resource: %{"kind" => "support_investigation", "turn_id" => turn_id} = resource
      }) do
    with {:ok, turn} <- Agents.get_turn(scope, turn_id) do
      case turn.status do
        :succeeded ->
          {:complete,
           Map.merge(
             turn.result,
             Map.drop(resource, ["kind", "id"]) |> Map.put("support_case_id", resource["id"])
           )}

        status when status in [:failed, :interrupted, :cancelled] ->
          {:error, %{"reason" => "support_investigation_#{status}", "details" => turn.error}}

        status
        when status in [
               :queued,
               :provisioning,
               :running,
               :waiting_for_input,
               :waiting_for_approval
             ] ->
          {:waiting, resource}
      end
    end
  end

  def poll(
        scope,
        %{resource: %{"kind" => "support_reply_review", "id" => review_id} = resource} = operation
      ) do
    with {:ok, review} <- Reviews.get_review(scope, review_id) do
      case review.status do
        :approved ->
          request_support_reply(
            scope,
            operation,
            Map.put(operation.request, "review_id", review.id)
          )

        :rejected ->
          {:error, %{"reason" => "review_rejected", "review_id" => review_id}}

        :requested ->
          {:waiting, resource}
      end
    end
  end

  def poll(
        scope,
        %{resource: %{"kind" => "support_reply_delivery", "review_id" => review_id}} = operation
      ),
      do:
        request_support_reply(
          scope,
          operation,
          Map.put(operation.request, "review_id", review_id)
        )

  defp deliver(scope, operation) do
    provider =
      case operation.node_type do
        "github.pull_requests.create" -> "github"
        "linear.comments.create" -> "linear"
      end

    attrs = %{
      effect_key: operation.id,
      provider: provider,
      kind: operation.node_type,
      connection: operation.request["_connection"],
      params: Map.drop(operation.request, ["_connection", "_publication"]),
      publication: operation.request["_publication"]
    }

    case Deliveries.deliver(scope, attrs) do
      {:ok, result} ->
        {:complete, result}

      {:error, :delivery_uncertain} ->
        with {:ok, delivery} <- Deliveries.get_by_key(scope, operation.id),
             do: {:waiting, %{"kind" => "delivery", "id" => delivery.id}}

      {:error, _reason} = error ->
        error
    end
  end

  defp request_publication(scope, operation, request) do
    with {:ok, publication} <-
           Agents.publish_branch(
             scope,
             Map.fetch!(request, "session_id"),
             Map.put(request, "operation_key", operation.id)
           ) do
      {:waiting, %{"kind" => "publication", "id" => publication.id}}
    end
  end

  defp request_deployment(scope, operation, request) do
    with {:ok, deployment} <-
           Apps.request_deployment(
             scope,
             Map.fetch!(request, "app_id"),
             Map.put(request, "operation_key", operation.id)
           ) do
      {:waiting, %{"kind" => "deployment", "id" => deployment.id}}
    end
  end

  defp request_support_reply(scope, operation, request) do
    case Support.send_reply(
           scope,
           request["case_id"],
           Map.put(request, "operation_key", operation.id)
         ) do
      {:ok, investigation} ->
        {:complete, %{"support_case_id" => investigation.id, "reply" => investigation.reply}}

      {:error, :delivery_uncertain} ->
        {:waiting,
         %{
           "kind" => "support_reply_delivery",
           "id" => operation.id,
           "review_id" => request["review_id"]
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp coding_session(scope, %{request: %{"session_id" => id}}), do: Agents.get_session(scope, id)

  defp coding_session(scope, operation) do
    attrs =
      operation.request
      |> Map.take(["title", "repository", "base_sha", "recipe", "connection_set", "app_id"])
      |> Map.put("operation_key", operation.id)

    Agents.start_session(scope, attrs)
  end

  defp effect_attrs(operation), do: Map.put(operation.request, "operation_key", operation.id)

  defp preview_result(%{status: "ready"} = preview), do: {:complete, Apps.result(preview)}
  defp preview_result(%{status: "failed", verification: verification}), do: {:error, verification}
  defp preview_result(preview), do: {:waiting, %{"kind" => "preview", "id" => preview.id}}

  defp log_option("limit"), do: :limit
  defp log_option("max_bytes"), do: :max_bytes
  defp log_option("wake"), do: :wake
  defp log_option("environment_id"), do: :environment_id
end
