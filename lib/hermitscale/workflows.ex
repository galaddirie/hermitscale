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

    with :ok <- Authorization.authorize(scope, "workflows:edit"),
         {:ok, changeset} <- prepare_graph(changeset, scope) do
      Repo.insert(changeset)
    end
  end

  def update_graph(%Scope{} = scope, %Graph{} = graph, attrs) do
    Scope.assert_same_org!(scope, graph)

    graph = get_graph!(scope, graph.id)
    changeset = Graph.update_changeset(graph, attrs)

    with :ok <- Authorization.authorize(scope, "workflows:edit"),
         {:ok, changeset} <- prepare_graph(changeset, scope) do
      Repo.update(changeset)
    end
  end

  defp prepare_graph(changeset, scope) do
    definition = Ecto.Changeset.get_field(changeset, :definition)

    with :ok <- Validator.validate(definition),
         {:ok, definition} <- Credentials.select_accounts(scope, definition),
         :ok <- Validator.validate(definition) do
      {:ok,
       changeset
       |> Ecto.Changeset.put_change(:definition, definition)
       |> put_validation_success()}
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
      Graph.update_changeset(get_graph!(scope, graph.id), attrs)
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
      {:error, _reason} = error -> error
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
             runner_opts(opts, graph.definition)
           ),
         :ok <- Runic.Runner.run(@runner, run.id, input, run_opts(opts, run_context)) do
      run_result(run, opts)
    end
  end

  def resume_run(%Scope{} = scope, %Run{} = run, opts \\ []) do
    run = get_run!(scope, run.id)

    with :ok <- Authorization.authorize(scope, "workflows:run") do
      do_resume_run(run, opts)
    end
  end

  defp do_resume_run(%Run{} = run, opts) do
    run
    |> Repo.preload(:graph)
    |> resume_with_graph(opts)
  end

  defp resume_with_graph(%Run{graph: nil}, _opts), do: {:error, :missing_graph}

  defp resume_with_graph(%Run{graph: %Graph{} = graph} = run, opts) do
    context = %ExecutionContext{
      organization_id: graph.org_id,
      actor_user_id: run.execution_actor_user_id,
      required_permissions: resume_permissions(run)
    }

    definition = Credentials.with_selections(graph.definition, run.account_selections)

    with {:ok, _actor_scope} <- Authorization.execution_scope(context),
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
        Keyword.merge(runner_opts(opts, graph.definition), resumed: true)
      )
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
    complete_run(run, workflow, terminal_ids(run.graph.definition))
  end

  defp complete_run(run, workflow, terminal_ids) do
    output = Map.new(terminal_ids, &{&1, Workflow.raw_productions(workflow, &1)})
    now = DateTime.utc_now(:second)

    update_run_result(run, %{
      status: :complete,
      output: json_payload(output),
      error: nil,
      completed_at: now
    })
  end

  @doc false
  def record_run_idle(
        %Runic.Runner.Worker{
          id: id,
          workflow: workflow,
          admission_causes: [],
          persistence: :saved
        },
        terminal_ids
      ) do
    id |> get_run_for_system!() |> complete_run(workflow, terminal_ids)
  end

  def record_run_idle(
        %Runic.Runner.Worker{
          id: id,
          admission_causes: [_cause | _causes]
        },
        _terminal_ids
      ) do
    mark_run_failed(id, "workflow_execution_failed")
  end

  # Runic retains the pending events, but a successful checkpoint retry does
  # not call on_idle again. Record the failed durable outcome explicitly.
  def record_run_idle(%Runic.Runner.Worker{id: id, persistence: {:error, _reason}}, _terminal_ids) do
    mark_run_failed(id, "workflow_persistence_failed")
  end

  defp mark_run_failed(id, reason) do
    id
    |> get_run_for_system!()
    |> update_run_result(%{
      status: :failed,
      output: nil,
      error: %{"reason" => reason},
      completed_at: DateTime.utc_now(:second)
    })
  end

  defp update_run_result(run, attrs) do
    result = run |> Run.changeset(attrs) |> Repo.update()

    with {:ok, run} <- result do
      :ok = Phoenix.PubSub.broadcast(Hermitscale.PubSub, run_topic(run.id), run_notification(run))
      {:ok, run}
    end
  end

  defp run_notification(%Run{status: :complete, id: id}), do: {:run_complete, id}
  defp run_notification(%Run{status: :failed, id: id}), do: {:run_failed, id}

  @doc """
  Subscribes the caller to `{:run_complete, id}` or `{:run_failed, id}` events.
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
  defp terminal_ids(definition) do
    consumed = MapSet.new(Map.fetch!(definition, "connections"), &Map.fetch!(&1, "from"))

    definition
    |> Map.fetch!("nodes")
    |> Enum.map(&Map.fetch!(&1, "id"))
    |> Enum.reject(&MapSet.member?(consumed, &1))
  end

  defp runner_opts(opts, definition) do
    # Capture only the admitted terminal IDs. An author can edit the graph
    # while it runs; completion must still describe that original computation.
    terminal_ids = terminal_ids(definition)

    opts
    |> Keyword.take([
      :checkpoint_strategy,
      :max_concurrency,
      :scheduler,
      :scheduler_opts,
      :executor,
      :executor_opts
    ])
    |> Keyword.put(:hooks, on_idle: &__MODULE__.record_run_idle(&1, terminal_ids))
  end

  defp run_opts(opts, run_context) do
    opts
    |> Keyword.take([:scheduler_policies])
    |> Keyword.put(:run_context, run_context)
  end

  defp run_result(%Run{} = run, opts) do
    case Keyword.get(opts, :executor) do
      :inline ->
        with {:ok, _workflow} <- Runic.Runner.get_workflow(@runner, run.id),
             {:ok, %{status: :saved}} <- Runic.Runner.persistence_status(@runner, run.id) do
          {:ok, get_run_for_system!(run.id)}
        else
          {:ok, %{status: {:error, reason}}} -> {:error, reason}
          {:ok, %{status: :pending}} -> {:ok, get_run_for_system!(run.id)}
          {:error, _reason} = error -> error
        end

      _other ->
        {:ok, run}
    end
  end

  defp put_validation_success(changeset) do
    changeset
    |> Ecto.Changeset.put_change(:validation_issues, [])
    |> Ecto.Changeset.put_change(:validated_at, DateTime.utc_now(:second))
  end

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
