defmodule Hermitscale.Triggers.Linear.Events.V1 do
  @moduledoc "Signed Linear resource events with freshness checks and delivery deduplication."
  @resources ~w(Reaction Cycle Issue Comment IssueLabel Project)
  use Hermitscale.Triggers.Behaviour,
    id: "linear.events",
    version: 1,
    mode: :webhook,
    requires: [credentials: [provider: "linear", scopes: ["admin"]]],
    params: [
      team_id: [type: :string],
      all_public_teams: [type: :boolean, default: false],
      resources: [type: {:list, :string}, default: ["Issue"]],
      actions: [type: {:list, :string}, default: []]
    ]

  alias Hermitscale.Integrations.WebhookSignature
  def provider_webhook, do: "linear"
  def resources, do: @resources

  @impl true
  def validate_params(params) do
    cond do
      Map.get(params, :team_id) not in [nil, ""] == params.all_public_teams ->
        {:error, "choose team_id or all_public_teams"}

      params.resources == [] or not Enum.all?(params.resources, &(&1 in @resources)) ->
        {:error, "resources must select supported Linear event types"}

      not Enum.all?(params.actions, &(&1 in ~w(create update remove))) ->
        {:error, "actions must be create, update, or remove"}

      true ->
        :ok
    end
  end

  @impl true
  def handle_request(%{method: "POST"} = request, params) do
    with :ok <-
           WebhookSignature.verify(
             request.raw_body,
             params._webhook_secret,
             request.headers["linear-signature"]
           ),
         {:ok, key} <-
           WebhookSignature.delivery_key(request.headers, "linear-delivery", "linear"),
         :ok <- fresh(request.body["webhookTimestamp"]),
         true <- request.body["webhookId"] == params._remote_id do
      case request.body["type"] in params.resources and
             (params.actions == [] or request.body["action"] in params.actions) do
        true -> {:fire, request.body, [idempotency_key: key]}
        false -> {:ignore, "event_not_selected"}
      end
    else
      false -> {:error, :unauthorized}
      {:error, _reason} = error -> error
    end
  end

  def handle_request(_request, _params), do: {:error, :unauthorized}

  defp fresh(timestamp) when is_integer(timestamp) do
    case abs(System.system_time(:millisecond) - timestamp) <= 60_000 do
      true -> :ok
      false -> {:error, :unauthorized}
    end
  end

  defp fresh(_timestamp), do: {:error, :unauthorized}
end
