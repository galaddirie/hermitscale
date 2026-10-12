defmodule Hermitscale.Triggers do
  @moduledoc """
  Public context for trigger activation, lifecycle, and firing.

  The workflow graph definition is the authoring source of truth for triggers;
  this context derives activation rows from it when a graph is activated,
  keeps the rows in sync with runtime processes (via the reconciler), and
  routes every firing through `Hermitscale.Triggers.Dispatcher`.
  """

  import Ecto.Query

  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Authorization
  alias Hermitscale.Integrations.ExecutionContext
  alias Hermitscale.Repo
  alias Hermitscale.Triggers.{Dispatcher, Trigger}
  alias Hermitscale.Workflows.{Catalog, Credentials, Graph, Validator}
  alias Hermitscale.Workflows.Nodes.Params
  alias Oban.Cron.Expression

  @pubsub Hermitscale.PubSub
  @topic "workflow_triggers"

  ## Queries

  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  def get_trigger!(%Scope{} = scope, id) do
    org_id = Scope.organization_id!(scope)

    Trigger
    |> join(:inner, [trigger], graph in assoc(trigger, :graph))
    |> where([_trigger, graph], graph.org_id == ^org_id)
    |> Repo.get!(id)
  end

  @doc false
  def get_trigger!(id), do: Repo.get!(Trigger, id)

  def list_triggers(%Scope{} = scope, %Graph{id: graph_id} = graph) do
    Scope.assert_same_org!(scope, graph)
    list_triggers(scope, graph_id)
  end

  def list_triggers(%Scope{} = scope, graph_id) when is_binary(graph_id) do
    org_id = Scope.organization_id!(scope)

    Trigger
    |> join(:inner, [trigger], graph in assoc(trigger, :graph))
    |> where(
      [trigger, graph],
      trigger.workflow_graph_id == ^graph_id and graph.org_id == ^org_id
    )
    |> order_by([trigger, _graph], asc: trigger.node_id)
    |> Repo.all()
  end

  defp list_triggers_for_graph(graph_id) do
    Trigger
    |> where([trigger], trigger.workflow_graph_id == ^graph_id)
    |> order_by([trigger], asc: trigger.node_id)
    |> Repo.all()
  end

  @doc """
  Enabled triggers that need a supervised source process (the reconciler's
  desired state).
  """
  def list_source_triggers do
    Trigger
    |> where([trigger], trigger.status == :enabled and trigger.mode in [:polling, :stream])
    |> Repo.all()
  end

  def get_webhook_trigger(token) when is_binary(token) do
    Repo.get_by(Trigger, webhook_token: token, mode: :webhook)
  end

  ## Activation

  @doc """
  Activates a graph: derives one trigger row per trigger node in the
  definition, upserts them (preserving webhook tokens and still-valid poll
  cursors), removes rows for deleted trigger nodes, and marks the graph
  active. Requires at least one trigger node.
  """
  def activate_graph(%Scope{} = scope, %Graph{} = graph) do
    Scope.assert_same_org!(scope, graph)
    graph = Hermitscale.Workflows.get_graph!(scope, graph.id)
    definition = graph.definition

    with :ok <- Authorization.authorize(scope, "workflows:activate"),
         :ok <- Authorization.authorize(scope, "workflows:run"),
         :ok <- Validator.validate(definition),
         {:ok, definition} <- Credentials.select_accounts(scope, definition),
         :ok <- Credentials.readiness(definition, Scope.execution_context(scope)),
         :ok <- Validator.validate(definition),
         {:ok, trigger_nodes} <- trigger_nodes(definition),
         {:ok, attrs_list} <-
           derive_trigger_attrs(%{graph | definition: definition}, trigger_nodes, scope.user.id) do
      existing = Map.new(list_triggers_for_graph(graph.id), &{&1.node_id, &1})
      keep_ids = Enum.map(attrs_list, & &1.node_id)

      result =
        Repo.transaction(fn ->
          triggers =
            Enum.map(attrs_list, fn attrs ->
              base = Map.get(existing, attrs.node_id, %Trigger{})

              base
              |> Ecto.Changeset.change(execution_actor_user_id: scope.user.id)
              |> Trigger.changeset(attrs)
              |> Repo.insert_or_update!()
            end)

          Trigger
          |> where([trigger], trigger.workflow_graph_id == ^graph.id)
          |> where([trigger], trigger.node_id not in ^keep_ids)
          |> Repo.delete_all()

          graph =
            graph
            |> Ecto.Changeset.change(definition: definition)
            |> Graph.status_changeset(%{status: :active})
            |> Repo.update!()

          %{graph: graph, triggers: triggers}
        end)

      with {:ok, activated} <- result do
        broadcast_changed(graph.id)
        {:ok, activated}
      end
    end
  end

  @doc """
  Deactivates a graph: disables its triggers (rows are kept so webhook URLs
  and poll cursors survive reactivation) and returns the graph to draft.
  """
  def deactivate_graph(%Scope{} = scope, %Graph{} = graph) do
    Scope.assert_same_org!(scope, graph)

    with :ok <- Authorization.authorize(scope, "workflows:activate") do
      do_deactivate_graph(graph)
    end
  end

  defp do_deactivate_graph(graph) do
    result =
      Repo.transaction(fn ->
        Trigger
        |> where([trigger], trigger.workflow_graph_id == ^graph.id)
        |> Repo.update_all(set: [status: :disabled])

        graph
        |> Graph.status_changeset(%{status: :draft})
        |> Repo.update!()
      end)

    with {:ok, graph} <- result do
      broadcast_changed(graph.id)
      {:ok, graph}
    end
  end

  def enable_trigger(%Scope{} = scope, %Trigger{} = trigger) do
    trigger = scope |> get_trigger!(trigger.id) |> Repo.preload(:graph)

    with :ok <- Authorization.authorize(scope, "workflows:activate") do
      with {:ok, _actor} <-
             Authorization.execution_scope(%ExecutionContext{
               organization_id: trigger.graph.org_id,
               actor_user_id: trigger.execution_actor_user_id,
               required_permissions: ["workflows:run", "workflows:activate"]
             }),
           :ok <-
             Credentials.readiness(trigger.graph.definition, %ExecutionContext{
               organization_id: trigger.graph.org_id,
               actor_user_id: trigger.execution_actor_user_id
             }) do
        set_status(trigger, :enabled, nil)
      end
    end
  end

  def disable_trigger(%Scope{} = scope, %Trigger{} = trigger) do
    trigger = scope |> get_trigger!(trigger.id) |> Repo.preload(:graph)

    with :ok <- Authorization.authorize(scope, "workflows:activate") do
      set_status(trigger, :disabled, nil)
    end
  end

  @doc """
  Flags a trigger as errored (e.g. a poller that failed past its retry
  threshold). Errored triggers stop firing until a user re-enables them.
  """
  def mark_errored(%Trigger{} = trigger, error) do
    set_status(trigger, :errored, %{
      "message" => to_error_message(error),
      "action" =>
        if(error == :execution_actor_ineligible, do: "reassign_actor", else: "repair_connection")
    })
  end

  ## Firing

  @doc """
  Fires a manual trigger with a user-supplied payload. Ad-hoc test runs of a
  draft graph should call `Workflows.start_run/4` directly instead — this path
  is for activated manual triggers, so firings share the audit trail.
  """
  def fire_manual(%Scope{} = scope, %Trigger{} = trigger, payload, opts \\ []) do
    %Trigger{mode: :manual} = trigger = get_trigger!(scope, trigger.id)
    trigger = Repo.preload(trigger, :graph)

    with :ok <- Authorization.authorize(scope, "workflows:run") do
      Dispatcher.fire(trigger, payload, Keyword.put(opts, :scope, scope))
    end
  end

  ## Runtime support

  @doc """
  Persists a poll/stream cursor. Written after events dispatch, so a crash in
  between replays the poll — the dispatcher's idempotency key absorbs that.
  """
  def persist_cursor(%Trigger{id: id}, cursor) when is_map(cursor) do
    Trigger
    |> where([trigger], trigger.id == ^id)
    |> Repo.update_all(set: [cursor: cursor, updated_at: DateTime.utc_now(:second)])

    :ok
  end

  def advance_next_fire_at(%Trigger{} = trigger, %DateTime{} = from) do
    Trigger
    |> where([t], t.id == ^trigger.id)
    |> Repo.update_all(
      set: [
        next_fire_at: compute_next_fire_at(trigger.schedule, from),
        updated_at: DateTime.utc_now(:second)
      ]
    )

    :ok
  end

  def catalog_module!(%Trigger{type: type, version: version}) do
    Catalog.fetch!(Catalog.index(), type, version)
  end

  @doc """
  Casts a trigger's stored raw config through its catalog params schema.
  """
  def cast_params!(%Trigger{} = trigger) do
    spec = catalog_module!(trigger).spec()
    Params.cast!(trigger.config, spec.params_schema, [], [])
  end

  def runtime_ctx(%Trigger{} = trigger) do
    %{trigger_id: trigger.id, graph_id: trigger.workflow_graph_id}
  end

  @doc """
  Resolves the trigger node's selected organization account from its graph. Trigger
  runtimes call this per poll/connect without caching credential material, so
  provider-side rotation is picked up automatically.
  """
  def credentials_for(%Trigger{} = trigger) do
    trigger = get_trigger!(trigger.id) |> Repo.preload(:graph)

    with {:ok, _scope, context} <- execution_scope(trigger) do
      Credentials.resolve_node(trigger.graph.definition, trigger.node_id, context)
    end
  end

  @doc "Validates the recorded activation actor against current WorkOS authority."
  def execution_scope(%Trigger{} = trigger) do
    trigger = get_trigger!(trigger.id) |> Repo.preload(:graph)

    context = %ExecutionContext{
      organization_id: trigger.graph.org_id,
      actor_user_id: trigger.execution_actor_user_id,
      required_permissions: ["workflows:run", "workflows:activate"]
    }

    with :enabled <- trigger.status,
         {:ok, scope} <- Authorization.execution_scope(context) do
      {:ok, scope, context}
    else
      status when status in [:disabled, :errored] ->
        {:error, :disabled}

      {:error, :execution_actor_ineligible} = error ->
        mark_errored(trigger, :execution_actor_ineligible)
        error

      error ->
        error
    end
  end

  @doc "Explicitly reassigns automation to the verified caller. Enable/disable preserve authority."
  def reassign_actor(%Scope{} = scope, %Trigger{} = trigger) do
    trigger = get_trigger!(scope, trigger.id)

    with :ok <- Authorization.authorize(scope, "workflows:activate"),
         :ok <- Authorization.authorize(scope, "workflows:run") do
      result =
        trigger
        |> Ecto.Changeset.change(execution_actor_user_id: scope.user.id, error: nil)
        |> Repo.update()

      with {:ok, assigned} <- result do
        broadcast_changed(assigned.workflow_graph_id)
        {:ok, assigned}
      end
    end
  end

  def source_ctx(%Trigger{} = trigger) do
    case credentials_for(trigger) do
      {:ok, credential} ->
        {:ok, Map.put(runtime_ctx(trigger), :credentials, credential)}

      {:error, {:connection_not_ready, _node, reason}} = error
      when reason in [:needs_reauthorization, :account_not_found, :insufficient_scopes] ->
        mark_errored(trigger, reason)
        error

      error ->
        error
    end
  end

  ## Derivation

  defp trigger_nodes(definition) do
    catalog = Catalog.index()

    nodes =
      definition
      |> Validator.node_specs()
      |> Enum.flat_map(fn node ->
        with {:ok, module} <- Catalog.fetch(catalog, node["type"], node["version"]),
             %{kind: :trigger} = spec <- module.__catalog_node__() do
          [{node, module, spec}]
        else
          _other -> []
        end
      end)

    case nodes do
      [] -> {:error, :no_triggers}
      nodes -> {:ok, nodes}
    end
  end

  defp derive_trigger_attrs(graph, trigger_nodes, actor_user_id) do
    existing = Map.new(list_triggers_for_graph(graph.id), &{&1.node_id, &1})

    trigger_nodes
    |> Enum.reduce_while([], fn {node, module, spec}, acc ->
      case derive_one(graph, node, module, spec, Map.get(existing, node["id"]), actor_user_id) do
        {:ok, attrs} -> {:cont, [attrs | acc]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      attrs_list -> {:ok, Enum.reverse(attrs_list)}
    end
  end

  defp derive_one(graph, node, module, spec, existing, actor_user_id) do
    config = node["params"] || %{}
    params = Params.cast!(config, spec.params_schema, [], [])

    base = %{
      id: (existing && existing.id) || Ecto.UUID.generate(),
      workflow_graph_id: graph.id,
      execution_actor_user_id: actor_user_id,
      node_id: node["id"],
      type: spec.id,
      version: spec.version,
      mode: spec.mode,
      config: config,
      status: :enabled,
      error: nil
    }

    with {:ok, mode_attrs} <- mode_attrs(spec.mode, graph, module, params, config, existing, base) do
      {:ok, Map.merge(base, mode_attrs)}
    end
  end

  defp mode_attrs(:webhook, _graph, _module, _params, _config, existing, _base) do
    token = (existing && existing.webhook_token) || generate_webhook_token()
    {:ok, %{webhook_token: token}}
  end

  defp mode_attrs(:schedule, _graph, _module, params, _config, _existing, _base) do
    cron = params[:cron]
    {:ok, %{schedule: cron, next_fire_at: compute_next_fire_at(cron, DateTime.utc_now())}}
  end

  defp mode_attrs(:polling, graph, module, params, config, existing, base) do
    # A cursor only survives reactivation when the config is unchanged; edited
    # params (a different sheet, a different filter) invalidate what the old
    # cursor was tracking.
    if existing && existing.cursor && existing.config == config do
      {:ok, %{cursor: existing.cursor}}
    else
      # Resolving credentials here doubles as an activation-time check: a missing
      # or incompatible account selection fails activation with a pointed error instead of a
      # poller crash-looping later.
      with {:ok, token} <- node_credentials(graph, base.node_id, base.execution_actor_user_id),
           ctx = %{trigger_id: base.id, graph_id: base.workflow_graph_id, credentials: token},
           {:ok, cursor} <- init_cursor(module, params, ctx, base.node_id) do
        {:ok, %{cursor: cursor}}
      end
    end
  end

  defp mode_attrs(:stream, graph, _module, _params, _config, _existing, base) do
    with {:ok, _token} <- node_credentials(graph, base.node_id, base.execution_actor_user_id) do
      {:ok, %{}}
    end
  end

  defp mode_attrs(_mode, _graph, _module, _params, _config, _existing, _base), do: {:ok, %{}}

  defp node_credentials(graph, node_id, actor_user_id) do
    case Credentials.resolve_node(
           graph.definition,
           node_id,
           %ExecutionContext{organization_id: graph.org_id, actor_user_id: actor_user_id}
         ) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:error, {:credentials, node_id, reason}}
    end
  end

  defp init_cursor(module, params, ctx, node_id) do
    case module.init_cursor(params, ctx) do
      {:ok, cursor} -> {:ok, cursor}
      {:error, reason} -> {:error, {:init_cursor, node_id, reason}}
    end
  end

  defp compute_next_fire_at(cron, %DateTime{} = from) do
    {:ok, expression} = Expression.parse(cron)

    case Expression.next_at(expression, from) do
      :unknown -> nil
      %DateTime{} = at -> DateTime.truncate(at, :second)
    end
  end

  defp generate_webhook_token do
    24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp set_status(%Trigger{} = trigger, status, error) do
    result =
      trigger
      |> Trigger.changeset(%{status: status, error: error})
      |> Repo.update()

    with {:ok, trigger} <- result do
      broadcast_changed(trigger.workflow_graph_id)
      {:ok, trigger}
    end
  end

  defp to_error_message(:execution_actor_ineligible), do: "Execution member needs reassignment"
  defp to_error_message(_error), do: "Automation stopped; check membership and connection setup"

  defp broadcast_changed(graph_id) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:workflow_triggers_changed, graph_id})
  end
end
