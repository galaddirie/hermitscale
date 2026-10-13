defmodule Hermitscale.ProductTools do
  @moduledoc "Authenticated product operations shared by MCP clients and application integrations."
  alias Hermitscale.{Agents, Apps, Workflows}

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
    "agents.publish" => "Request branch publication.",
    "apps.inspect" => "Read an app and recorded environments/deployments.",
    "apps.create" => "Create an app registry record.",
    "apps.build" => "Start a coding conversation for an app.",
    "apps.preview" => "Explicitly start a private preview.",
    "apps.logs" => "Read stored bounded logs.",
    "deployments.request" => "Request release activation.",
    "deployments.inspect" => "Read recorded release verification."
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
  def permission("apps.inspect"), do: "apps:read"
  def permission("apps.logs"), do: "apps:read"
  def permission("apps.preview"), do: "apps:write"
  def permission("apps." <> action) when action in ["create", "build"], do: "apps:write"
  def permission("deployments.request"), do: "apps:deploy"
  def permission("deployments.inspect"), do: "apps:read"
  def permission(_action), do: nil

  def resource_id(name, args) when is_map(args) do
    field =
      case name do
        action
        when action in ~w(workflows.inspect runs.status agents.inspect apps.inspect deployments.inspect) ->
          "id"

        "runs.start" ->
          "graph_id"

        action when action in ~w(agents.continue agents.publish) ->
          "session_id"

        "agents.cancel" ->
          "turn_id"

        action
        when action in ~w(apps.build apps.preview apps.logs deployments.request) ->
          "app_id"

        _other ->
          nil
      end

    case field do
      nil -> nil
      field -> Map.get(args, field)
    end
  end

  def resource_id(_name, _args), do: nil

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

  defp case_validation(:ok), do: {:ok, %{valid: true}}
  defp case_validation({:error, reason}), do: {:error, reason}

  defp idempotency(name, args) do
    if name in ~w(workflows.create runs.start agents.continue agents.publish apps.create apps.build apps.preview deployments.request) and
         not (is_binary(args["operation_key"]) and byte_size(args["operation_key"]) in 8..128),
       do: {:error, :idempotency_key_required},
       else: :ok
  end
end
