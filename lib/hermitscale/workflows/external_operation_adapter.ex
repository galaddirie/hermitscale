defmodule Hermitscale.Workflows.ExternalOperationAdapter do
  @moduledoc "Dispatches workflow intent exclusively through the owning public context."
  alias Hermitscale.{Agents, Apps}

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
             |> Map.take([
               "instructions",
               "budget_cents",
               "timeout_seconds",
               "result_schema",
               "verification_commands"
             ])
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

  def dispatch(scope, %{node_type: "agents.publish_branch", request: request} = operation),
    do: request_publication(scope, operation, request)

  def dispatch(scope, %{node_type: "apps.preview.create", request: request} = operation) do
    with {:ok, preview} <-
           Apps.ensure_preview(scope, Map.fetch!(request, "app_id"), effect_attrs(operation)) do
      preview_result(preview)
    end
  end

  def dispatch(scope, %{node_type: "apps.deploy", request: request} = operation),
    do: request_deployment(scope, operation, request)

  def dispatch(scope, %{node_type: "apps.logs.read", request: request}) do
    opts =
      request
      |> Map.take(["limit", "max_bytes", "wake", "environment_id"])
      |> Enum.map(fn {key, value} -> {log_option(key), value} end)

    with {:ok, logs} <- Apps.read_logs(scope, Map.fetch!(request, "app_id"), opts) do
      {:complete, %{"logs" => logs}}
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

        status when status in [:queued, :running, :uncertain] ->
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
               "maintenance"
             ] ->
          {:waiting, resource}
      end
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
