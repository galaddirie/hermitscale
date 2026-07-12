defmodule Hermitscale.Workflows do
  @moduledoc """
  Public context for workflow graph storage, compilation, execution, and recovery.
  """

  import Ecto.Query

  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Repo
  alias Hermitscale.Workflows.{Compiler, Credentials, Graph, Run, Validator}
  alias Runic.Workflow

  @runner Hermitscale.WorkflowRunner

  def list_graphs(%Scope{} = scope) do
    Graph
    |> where([graph], graph.user_id == ^scope.user.id)
    |> order_by([graph], asc: graph.name)
    |> Repo.all()
  end

  def get_graph!(%Scope{} = scope, id) do
    Repo.get_by!(Graph, id: id, user_id: scope.user.id)
  end

  def create_graph(%Scope{} = scope, attrs) do
    changeset = Graph.authoring_changeset(%Graph{}, attrs, scope)
    definition = get_definition(attrs)

    with :ok <- Validator.validate(definition),
         changeset <- put_validation_success(changeset) do
      Repo.insert(changeset)
    else
      {:error, issues} when is_list(issues) ->
        {:error, Graph.put_validation_issues(changeset, issues)}
    end
  end

  def update_graph(%Scope{} = scope, %Graph{} = graph, attrs) do
    Scope.assert_owner!(scope, graph)

    changeset = Graph.authoring_changeset(graph, attrs, scope)
    definition = get_definition(attrs) || graph.definition

    with :ok <- Validator.validate(definition),
         changeset <- put_validation_success(changeset) do
      Repo.update(changeset)
    else
      {:error, issues} when is_list(issues) ->
        {:error, Graph.put_validation_issues(changeset, issues)}
    end
  end

  def change_graph(%Scope{} = scope, %Graph{} = graph, attrs \\ %{}) do
    Scope.assert_owner!(scope, graph)
    Graph.authoring_changeset(graph, attrs, scope)
  end

  def validate_graph(graph), do: Validator.validate(graph)
  def graph_issues(graph), do: Validator.issues(graph)
  def compile_graph(graph), do: Compiler.compile(graph)

  def create_run(%Scope{} = scope, %Graph{} = graph, attrs \\ %{}) do
    Scope.assert_owner!(scope, graph)
    insert_run(graph, attrs)
  end

  defp insert_run(%Graph{} = graph, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put_new("id", Ecto.UUID.generate())
      |> Map.put("workflow_graph_id", graph.id)

    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end

  def get_run!(%Scope{} = scope, id) do
    Run
    |> join(:inner, [run], graph in assoc(run, :graph))
    |> where([_run, graph], graph.user_id == ^scope.user.id)
    |> Repo.get!(id)
  end

  @doc false
  def get_run_for_system!(id), do: Repo.get!(Run, id)

  def start_run(%Scope{} = scope, %Graph{} = graph, input, opts \\ []) do
    Scope.assert_owner!(scope, graph)
    do_start_run(graph, input, opts)
  end

  @doc false
  def start_run_from_trigger(%Graph{} = graph, input, opts \\ []) do
    do_start_run(graph, input, opts)
  end

  defp do_start_run(%Graph{} = graph, input, opts) do
    now = DateTime.utc_now(:second)

    with {:ok, workflow} <- Compiler.compile(graph.definition),
         {:ok, run_context} <-
           Credentials.resolve_run_context(
             graph.definition,
             workflow,
             Keyword.get(opts, :run_context, %{})
           ),
         workflow <- Workflow.put_run_context(workflow, run_context),
         {:ok, run} <-
           insert_run(graph, %{
             input: json_payload(input),
             status: :running,
             started_at: now
           }),
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
    do_resume_run(run, opts)
  end

  defp do_resume_run(%Run{} = run, opts) do
    run = Repo.preload(run, :graph)

    with %Graph{} = graph <- run.graph,
         {:ok, base_workflow} <- Compiler.compile(graph.definition),
         {:ok, run_context} <-
           Credentials.resolve_run_context(
             graph.definition,
             base_workflow,
             Keyword.get(opts, :run_context, %{})
           ),
         {store_module, store_state} <- Runic.Runner.get_store(@runner),
         {:ok, event_stream} <- store_module.stream(run.id, store_state) do
      workflow =
        event_stream
        |> Enum.to_list()
        |> Workflow.from_events(base_workflow)
        |> Workflow.put_run_context(run_context)

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
