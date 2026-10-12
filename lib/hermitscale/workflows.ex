defmodule Hermitscale.Workflows do
  @moduledoc """
  Public context for workflow graph storage, compilation, execution, and recovery.
  """

  import Ecto.Query

  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Authorization
  alias Hermitscale.Integrations.ExecutionContext
  alias Hermitscale.Repo
  alias Hermitscale.Workflows.{Compiler, Credentials, Graph, Replay, Run, Validator}
  alias Runic.Workflow

  @runner Hermitscale.WorkflowRunner

  def list_graphs(%Scope{} = scope) do
    org_id = Scope.organization_id!(scope)

    Graph
    |> where([graph], graph.org_id == ^org_id)
    |> order_by([graph], asc: graph.name)
    |> Repo.all()
  end

  def get_graph!(%Scope{} = scope, id) do
    Repo.get_by!(Graph, id: id, org_id: Scope.organization_id!(scope))
  end

  def create_graph(%Scope{} = scope, attrs) do
    changeset = Graph.create_changeset(%Graph{}, attrs, scope)
    definition = get_definition(attrs)

    with :ok <- Authorization.authorize(scope, "workflows:edit"),
         :ok <- Validator.validate(definition),
         {:ok, definition} <- Credentials.select_accounts(scope, definition),
         changeset <- Ecto.Changeset.put_change(changeset, :definition, definition),
         :ok <- Validator.validate(definition),
         changeset <- put_validation_success(changeset) do
      Repo.insert(changeset)
    else
      {:error, issues} when is_list(issues) ->
        {:error, Graph.put_validation_issues(changeset, issues)}

      {:error, _reason} = error ->
        error
    end
  end

  def update_graph(%Scope{} = scope, %Graph{} = graph, attrs) do
    Scope.assert_same_org!(scope, graph)

    graph = get_graph!(scope, graph.id)
    changeset = Graph.update_changeset(graph, attrs, scope: scope)
    definition = get_definition(attrs) || graph.definition

    with :ok <- Authorization.authorize(scope, "workflows:edit"),
         :ok <- Validator.validate(definition),
         {:ok, definition} <- Credentials.select_accounts(scope, definition),
         changeset <- Ecto.Changeset.put_change(changeset, :definition, definition),
         :ok <- Validator.validate(definition),
         changeset <- put_validation_success(changeset) do
      Repo.update(changeset)
    else
      {:error, issues} when is_list(issues) ->
        {:error, Graph.put_validation_issues(changeset, issues)}

      {:error, _reason} = error ->
        error
    end
  end

  def change_graph(%Scope{} = scope, %Graph{} = graph, attrs \\ %{}) do
    Scope.assert_same_org!(scope, graph)

    with :ok <- Authorization.authorize(scope, "workflows:edit") do
      Graph.update_changeset(get_graph!(scope, graph.id), attrs, scope: scope)
    end
  end

  def validate_graph(graph), do: Validator.validate(graph)
  def graph_issues(graph), do: Validator.issues(graph)
  def compile_graph(graph), do: Compiler.compile(graph)

  def create_run(%Scope{} = scope, %Graph{} = graph, attrs \\ %{}) do
    Scope.assert_same_org!(scope, graph)

    with :ok <- Authorization.authorize(scope, "workflows:run") do
      graph = get_graph!(scope, graph.id)
      insert_run(graph, attrs, Scope.execution_context(scope), scope.user.id, nil)
    end
  end

  defp insert_run(%Graph{} = graph, attrs, context, initiator, trigger_id) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put_new("id", Ecto.UUID.generate())
      |> Map.put("workflow_graph_id", graph.id)

    %Run{
      initiated_by_user_id: initiator,
      execution_actor_user_id: context.actor_user_id,
      trigger_id: trigger_id,
      account_selections: Credentials.selections(graph.definition)
    }
    |> Run.changeset(attrs)
    |> Repo.insert()
  end

  def get_run!(%Scope{} = scope, id) do
    org_id = Scope.organization_id!(scope)

    Run
    |> join(:inner, [run], graph in assoc(run, :graph))
    |> where([_run, graph], graph.org_id == ^org_id)
    |> Repo.get!(id)
  end

  @doc false
  def get_run_for_system!(id), do: Repo.get!(Run, id)

  def start_run(%Scope{} = scope, %Graph{} = graph, input, opts \\ []) do
    Scope.assert_same_org!(scope, graph)

    with :ok <- Authorization.authorize(scope, "workflows:run") do
      graph = get_graph!(scope, graph.id)
      do_start_run(graph, input, opts, Scope.execution_context(scope), scope.user.id, nil)
    end
  end

  @doc false
  def start_run_from_trigger(%Scope{} = scope, %Graph{} = graph, input, opts, trigger_id, context) do
    Scope.assert_same_org!(scope, graph)

    with :ok <- Authorization.authorize(scope, "workflows:run"),
         true <-
           context.organization_id == graph.org_id and context.actor_user_id == scope.user.id do
      do_start_run(
        get_graph!(scope, graph.id),
        input,
        opts,
        context,
        if(trigger_id && "workflows:activate" in context.required_permissions,
          do: nil,
          else: scope.user.id
        ),
        trigger_id
      )
    else
      false -> {:error, :invalid_execution_identity}
      error -> error
    end
  end

  defp do_start_run(%Graph{} = graph, input, opts, context, initiator, trigger_id) do
    now = DateTime.utc_now(:second)

    with {:ok, workflow} <- Compiler.compile(graph.definition),
         definition_event <- Replay.definition_event(workflow),
         {:ok, run_context} <-
           Credentials.resolve_run_context(
             graph.definition,
             workflow,
             Keyword.get(opts, :run_context, %{}),
             context
           ),
         workflow <- Workflow.put_run_context(workflow, run_context),
         {:ok, run} <-
           insert_run(
             graph,
             %{input: json_payload(input), status: :running, started_at: now},
             context,
             initiator,
             trigger_id
           ),
         {store_module, store_state} <- Runic.Runner.get_store(@runner),
         {:ok, _cursor} <- store_module.append(run.id, [definition_event], store_state),
         {:ok, _pid} <-
           Runic.Runner.start_workflow(
             @runner,
             run.id,
             workflow,
             runner_opts(opts)
           ),
         :ok <- Runic.Runner.run(@runner, run.id, input, run_opts(opts, run_context)) do
      {:ok, maybe_mark_inline_complete(run, opts)}
    end
  end

  def resume_run(%Scope{} = scope, %Run{} = run, opts \\ []) do
    run = get_run!(scope, run.id)

    with :ok <- Authorization.authorize(scope, "workflows:run") do
      do_resume_run(run, opts)
    end
  end

  defp do_resume_run(%Run{} = run, opts) do
    run = Repo.preload(run, :graph)

    context = %ExecutionContext{
      organization_id: run.graph.org_id,
      actor_user_id: run.execution_actor_user_id,
      required_permissions: resume_permissions(run)
    }

    definition = Credentials.with_selections(run.graph.definition, run.account_selections)

    with {:ok, _actor_scope} <- Authorization.execution_scope(context),
         %Graph{} = graph <- run.graph,
         {:ok, base_workflow} <- Compiler.compile(graph.definition),
         {:ok, run_context} <-
           Credentials.resolve_run_context(
             definition,
             base_workflow,
             Keyword.get(opts, :run_context, %{}),
             context
           ),
         {store_module, store_state} <- Runic.Runner.get_store(@runner),
         {:ok, event_stream} <- store_module.stream(run.id, store_state),
         {:ok, workflow} <- Replay.restore(event_stream, base_workflow) do
      workflow = Workflow.put_run_context(workflow, run_context)

      Runic.Runner.start_workflow(
        @runner,
        run.id,
        workflow,
        Keyword.merge(runner_opts(opts), resumed: true)
      )
    else
      nil -> {:error, :missing_graph}
      error -> error
    end
  end

  defp resume_permissions(%Run{trigger_id: nil}), do: ["workflows:run"]

  defp resume_permissions(%Run{input: input}) do
    case get_in(input, ["value", "trigger", "mode"]) do
      "manual" -> ["workflows:run"]
      _unattended -> ["workflows:run", "workflows:activate"]
    end
  end

  @doc "Returns non-secret account selections, requirements and setup readiness for the editor."
  def connection_status(%Scope{} = scope, %Graph{} = graph) do
    graph = get_graph!(scope, graph.id)

    %{
      requirements: Credentials.requirements(graph.definition),
      selections: Credentials.selections(graph.definition),
      readiness: Credentials.readiness(graph.definition, Scope.execution_context(scope))
    }
  end

  def mark_run_complete(run_id, %Workflow{} = workflow) do
    run = run_id |> get_run_for_system!() |> Repo.preload(:graph)
    output = terminal_outputs(workflow, run.graph.definition)
    now = DateTime.utc_now(:second)

    result =
      run
      |> Run.changeset(%{status: :complete, output: json_payload(output), completed_at: now})
      |> Repo.update()

    with {:ok, run} <- result do
      Phoenix.PubSub.broadcast(Hermitscale.PubSub, run_topic(run.id), {:run_complete, run.id})
      {:ok, run}
    end
  end

  @doc """
  Subscribes the caller to completion events for a run (`{:run_complete, id}`).
  """
  def subscribe_run(%Scope{} = scope, run_id) do
    _run = get_run!(scope, run_id)
    subscribe_run_for_system(run_id)
  end

  @doc false
  def subscribe_run_for_system(run_id) do
    Phoenix.PubSub.subscribe(Hermitscale.PubSub, run_topic(run_id))
  end

  defp run_topic(run_id), do: "workflow_runs:#{run_id}"

  # A run's result is the output of its terminal nodes — the graph nodes nothing
  # else consumes. Keyed by node id so multi-output graphs round-trip cleanly,
  # and so intermediate facts and map fan-out plumbing stay out of the result.
  defp terminal_outputs(workflow, definition) do
    consumed = MapSet.new(definition["connections"] || [], & &1["from"])

    definition["nodes"]
    |> Enum.map(& &1["id"])
    |> Enum.reject(&MapSet.member?(consumed, &1))
    |> Map.new(fn id -> {id, Workflow.raw_productions(workflow, id)} end)
  end

  defp runner_opts(opts) do
    opts
    |> Keyword.take([
      :checkpoint_strategy,
      :max_concurrency,
      :scheduler,
      :scheduler_opts,
      :executor,
      :executor_opts
    ])
    |> Keyword.put_new(:on_complete, {__MODULE__, :mark_run_complete, []})
  end

  defp run_opts(opts, run_context) do
    opts
    |> Keyword.take([:scheduler_policies])
    |> Keyword.put(:run_context, run_context)
  end

  defp maybe_mark_inline_complete(%Run{} = run, opts) do
    case Keyword.get(opts, :executor) do
      :inline ->
        with {:ok, workflow} <- Runic.Runner.get_workflow(@runner, run.id),
             false <- Workflow.is_runnable?(workflow),
             {:ok, run} <- mark_run_complete(run.id, workflow) do
          run
        else
          _other -> run
        end

      _other ->
        run
    end
  end

  defp put_validation_success(changeset) do
    changeset
    |> Ecto.Changeset.put_change(:validation_issues, [])
    |> Ecto.Changeset.put_change(:validated_at, DateTime.utc_now(:second))
  end

  defp get_definition(%{"definition" => definition}), do: definition
  defp get_definition(%{definition: definition}), do: definition
  defp get_definition(_attrs), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  # Round-trips through JSON so stored terms match what reads back from the DB
  # (atom keys become strings, etc.). Non-serializable data — e.g. a node that
  # returns a tuple or PID — crashes here by design; that signals a real bug,
  # not something to coerce into a plausible-looking value.
  defp jsonable(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp json_payload(value), do: %{"value" => jsonable(value)}
end
