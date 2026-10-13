defmodule Hermitscale.ProductTools do
  @moduledoc "Authenticated product operations shared by MCP clients and application integrations."
  alias Hermitscale.{Agents, Apps, Reviews, Support, Workflows}

  @tools %{
    "workflows.list" => "List authorized workflow definitions.",
    "workflows.inspect" => "Inspect a definition.",
    "workflows.validate" => "Validate a graph before admission.",
    "workflows.create" => "Save an authorized workflow definition.",
    "runs.start" => "Start a workflow and return its durable run identity.",
    "runs.status" => "Read stored run status.",
    "agents.inspect" => "Read conversation, turn and stored event history.",
    "agents.continue" => "Admit a turn in an existing conversation.",
    "agents.cancel" => "Record cancellation intent.",
    "agents.publish" => "Request reviewed branch publication.",
    "reviews.request" => "Request an exact digest-bound review.",
    "reviews.decide" => "Record a review decision.",
    "apps.inspect" => "Read an app and recorded environments/deployments.",
    "apps.create" => "Create an app registry record.",
    "apps.build" => "Start a coding conversation for an app.",
    "apps.preview" => "Explicitly start a private preview.",
    "apps.logs" => "Read stored bounded logs.",
    "apps.verify_defect" =>
      "Verify an exact response from the active deployed app and store evidence.",
    "deployments.request" => "Request reviewed release activation.",
    "deployments.inspect" => "Read recorded release verification.",
    "support.subscribe" => "Map an app environment to an authorized Linear ticket prefix.",
    "support.investigate" => "Investigate a ticket against its mapped deployed app revision.",
    "support.inspect" => "Read an authorized investigation.",
    "support.reply" => "Deliver an exact reviewed support reply."
  }
  def definitions(actions) do
    @tools
    |> Enum.filter(fn {name, _} -> name in actions end)
    |> Enum.map(fn {name, description} ->
      %{
        name: name,
        description: description,
        inputSchema: Hermitscale.ProductToolSchema.schema(name)
      }
    end)
  end

  def permission("workflows." <> action) when action in ["create"], do: "workflows:edit"
  def permission("workflows." <> _action), do: "workflows:run"
  def permission("runs." <> _action), do: "workflows:run"
  def permission("agents.inspect"), do: "agents:read"
  def permission("agents.publish"), do: "agents:publish"
  def permission("agents." <> _action), do: "agents:run"
  def permission("reviews.decide"), do: "reviews:decide"
  def permission("reviews." <> _action), do: "reviews:request"
  def permission("apps.inspect"), do: "apps:read"
  def permission("apps.logs"), do: "apps:read"
  def permission("apps.preview"), do: "apps:write"
  def permission("apps.verify_defect"), do: "apps:deploy"
  def permission("apps." <> _action), do: "apps:write"
  def permission("deployments.request"), do: "apps:deploy"
  def permission("deployments.inspect"), do: "apps:read"
  def permission("support.subscribe"), do: "apps:write"
  def permission("support.investigate"), do: "support:investigate"
  def permission("support.inspect"), do: "support:investigate"
  def permission("support.reply"), do: "support:reply"
  def permission(_action), do: nil

  def resource_id(name, args) when is_map(args) do
    field =
      case name do
        action
        when action in ~w(workflows.inspect runs.status agents.inspect reviews.decide apps.inspect deployments.inspect support.inspect) ->
          "id"

        "runs.start" ->
          "graph_id"

        action when action in ~w(agents.continue agents.publish) ->
          "session_id"

        "agents.cancel" ->
          "turn_id"

        action
        when action in ~w(apps.build apps.preview apps.logs apps.verify_defect deployments.request support.subscribe) ->
          "app_id"

        "support.investigate" ->
          "subscription_id"

        "support.reply" ->
          "case_id"

        "reviews.request" ->
          nil

        _other ->
          nil
      end

    if name == "reviews.request",
      do: review_resource_id(args),
      else: if(field, do: Map.get(args, field))
  end

  def resource_id(_name, _args), do: nil

  defp review_resource_id(%{"action" => action, "target" => target}) when is_map(target) do
    case action do
      "agents.publish_branch" -> target["session_id"]
      "apps.deploy" -> target["app_id"] || target["environment_id"]
      action when action in ["apps.publish", "apps.restore_data"] -> target["environment_id"]
      "support.reply" -> target["case_id"]
      _other -> target["resource_id"]
    end
  end

  defp review_resource_id(_args), do: nil

  def resource_required?(name),
    do: name not in ~w(protocol workflows.list workflows.validate workflows.create apps.create)

  def execute(scope, "workflows.list", args, resources)
      when is_map(args) and is_list(resources) do
    with :ok <- Hermitscale.Authorization.authorize(scope, permission("workflows.list")) do
      {:ok, Enum.filter(Workflows.list_graphs(scope), &(&1.id in resources))}
    end
  end

  def execute(scope, name, args, _resources), do: execute(scope, name, args)

  def execute(scope, name, args) when is_map(args) do
    with permission when is_binary(permission) <- permission(name),
         :ok <- Hermitscale.Authorization.authorize(scope, permission),
         :ok <- idempotency(name, args),
         :ok <- Hermitscale.ProductToolSchema.validate(name, args) do
      call(scope, name, args)
    else
      nil -> {:error, :unknown_tool}
      {:error, _} = error -> error
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :invalid_identifier}
  end

  def execute(_scope, _name, _args), do: {:error, :invalid_arguments}
  defp call(scope, "workflows.list", _args), do: {:ok, Workflows.list_graphs(scope)}
  defp call(scope, "workflows.inspect", args), do: {:ok, Workflows.get_graph!(scope, args["id"])}

  defp call(_scope, "workflows.validate", args),
    do: case_validation(Workflows.validate_graph(args["definition"]))

  defp call(scope, "workflows.create", args) do
    if Map.get(args, "status", "draft") == "draft",
      do: Workflows.create_graph(scope, args),
      else: {:error, :workflow_activation_requires_explicit_authority}
  end

  defp call(scope, "runs.start", args),
    do:
      Workflows.start_run(scope, Workflows.get_graph!(scope, args["graph_id"]), args["input"],
        run_id: args["operation_key"]
      )

  defp call(scope, "runs.status", args), do: {:ok, Workflows.get_run!(scope, args["id"])}

  defp call(scope, "agents.inspect", args) do
    with {:ok, session} <- Agents.get_session(scope, args["id"]),
         do:
           {:ok,
            %{
              session: session,
              turns: Agents.list_turns(scope, session.id),
              events: Agents.list_events(scope, session.id)
            }}
  end

  defp call(scope, "agents.continue", args),
    do: Agents.submit_turn(scope, args["session_id"], args)

  defp call(scope, "agents.cancel", args), do: Agents.cancel_turn(scope, args["turn_id"])

  defp call(scope, "agents.publish", args),
    do: Agents.publish_branch(scope, args["session_id"], args)

  defp call(scope, "reviews.request", %{"target" => target} = args)
       when is_map(target) and map_size(target) > 0,
       do: Reviews.request(scope, args)

  defp call(_scope, "reviews.request", _args), do: {:error, :review_target_required}

  defp call(scope, "reviews.decide", %{"id" => id, "decision" => "approved"}),
    do: Reviews.decide(scope, id, :approved)

  defp call(scope, "reviews.decide", %{"id" => id, "decision" => "rejected"}),
    do: Reviews.decide(scope, id, :rejected)

  defp call(_scope, "reviews.decide", _args), do: {:error, :invalid_decision}

  defp call(scope, "apps.inspect", args) do
    with {:ok, app} <- Apps.get_app(scope, args["id"]),
         do:
           {:ok,
            %{
              app: app,
              environments: Apps.list_environments(scope, app.id),
              deployments: Apps.list_deployments(scope, app.id)
            }}
  end

  defp call(scope, "apps.create", args), do: Apps.create_app(scope, args)
  defp call(scope, "apps.build", args), do: Apps.start_build(scope, args["app_id"], args)
  defp call(scope, "apps.preview", args), do: Apps.ensure_preview(scope, args["app_id"], args)

  defp call(scope, "apps.logs", args) do
    case Map.get(args, "limit", 100) do
      limit when is_integer(limit) and limit in 1..200 ->
        case Apps.read_logs(scope, args["app_id"], limit: limit) do
          logs when is_list(logs) -> {:ok, logs}
          {:error, _reason} = error -> error
        end

      _invalid ->
        {:error, :invalid_limit}
    end
  end

  defp call(scope, "deployments.request", args),
    do: Apps.request_deployment(scope, args["app_id"], args)

  defp call(scope, "deployments.inspect", args), do: Apps.get_deployment(scope, args["id"])

  defp call(scope, "apps.verify_defect", args),
    do: Apps.verify_defect(scope, args["app_id"], args["environment_id"], args)

  defp call(scope, "support.subscribe", args),
    do: Support.register_subscription(scope, args["app_id"], args["environment_id"], args)

  defp call(scope, "support.investigate", args),
    do:
      Support.investigate(
        scope,
        args["subscription_id"],
        args["ticket_id"],
        args["operation_key"]
      )

  defp call(scope, "support.inspect", args), do: Support.get_case(scope, args["id"])
  defp call(scope, "support.reply", args), do: Support.send_reply(scope, args["case_id"], args)
  defp case_validation(:ok), do: {:ok, %{valid: true}}
  defp case_validation({:error, reason}), do: {:error, reason}

  defp idempotency(name, args) do
    if name in ~w(workflows.create runs.start agents.continue agents.publish reviews.request apps.create apps.build apps.preview deployments.request support.subscribe support.investigate support.reply) and
         not (is_binary(args["operation_key"]) and byte_size(args["operation_key"]) in 8..128),
       do: {:error, :idempotency_key_required},
       else: :ok
  end
end
