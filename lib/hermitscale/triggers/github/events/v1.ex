defmodule Hermitscale.Triggers.GitHub.Events.V1 do
  @moduledoc "Signed repository webhooks with n8n-style event selection and delivery deduplication."
  @events ~w(check_run check_suite commit_comment create delete deploy_key deployment deployment_status fork github_app_authorization gollum installation installation_repositories issue_comment issues label marketplace_purchase member membership meta milestone org_block organization page_build project project_card project_column public pull_request pull_request_review pull_request_review_comment push release repository repository_import repository_vulnerability_alert security_advisory star status team team_add watch workflow_run workflow_job discussion discussion_comment merge_group)
  use Hermitscale.Triggers.Behaviour,
    id: "github.events",
    version: 1,
    mode: :webhook,
    requires: [credentials: [provider: "github", scopes: ["admin:repo_hook"]]],
    params: [
      owner: [type: :string, required: true],
      repo: [type: :string, required: true],
      events: [type: {:list, :string}, default: ["push"]],
      actions: [type: {:list, :string}, default: []]
    ]

  alias Hermitscale.Integrations.WebhookSignature
  def provider_webhook, do: "github"
  def events, do: @events

  @impl true
  def validate_params(params) do
    case params.events != [] and Enum.all?(params.events, &(&1 in @events or &1 == "*")) and
           ("*" not in params.events or params.events == ["*"]) do
      true -> :ok
      false -> {:error, "events must select supported GitHub webhook events or only *"}
    end
  end

  @impl true
  def handle_request(%{method: "POST"} = request, params) do
    with :ok <-
           WebhookSignature.verify(
             request.raw_body,
             params._webhook_secret,
             request.headers["x-hub-signature-256"],
             "sha256="
           ),
         {:ok, key} <-
           WebhookSignature.delivery_key(request.headers, "x-github-delivery", "github") do
      handle_event(request, params, key)
    end
  end

  def handle_request(_request, _params), do: {:error, :unauthorized}

  defp handle_event(%{headers: %{"x-github-event" => "ping"}}, _params, _key),
    do: {:reply, 200, %{}}

  defp handle_event(request, params, key) do
    expected = String.downcase(params.owner <> "/" <> params.repo)

    repository =
      case request.body do
        %{"repository" => %{"full_name" => name}} -> name
        _body -> nil
      end

    cond do
      not is_binary(repository) or String.downcase(repository) != expected ->
        {:error, :unauthorized}

      request.headers["x-github-event"] not in params.events and "*" not in params.events ->
        {:ignore, "event_not_selected"}

      params.actions != [] and request.body["action"] not in params.actions ->
        {:ignore, "event_not_selected"}

      true ->
        {:fire, request.body, [idempotency_key: key]}
    end
  end
end
