defmodule Hermitscale.Workflows.ExternalOperations do
  @moduledoc """
  Durable waiting and continuation using Runic's public dispatch and acceptance APIs.

  Waiting reserves an activation in Postgres while leaving its native activation
  pending. Each graph checkpoint and accepted terminal outcome share a transaction
  with the reservation, so restarting between notifications cannot publish a
  second output. Owner contexts perform external work outside this transaction.
  """
  import Ecto.Query
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Integrations.ExecutionContext
  alias Hermitscale.{Authorization, Repo, Workflows}

  alias Hermitscale.Workflows.{
    Catalog,
    Compiler,
    Credentials,
    Engine,
    ExternalOperation,
    ExternalOperationAdapter,
    ExternalOperationWorker,
    PostgresStore,
    Replay,
    Run
  }

  alias Hermitscale.Workflows.Engine.{Metadata, Node}
  alias Runic.Workflow
  alias Runic.Workflow.{PolicyDriver, SchedulerPolicy}
  alias Runic.Workflow.SingleOutput.Result

  @batch_limit 100

  def external_definition?(nil), do: false

  def external_definition?(definition) do
    Enum.any?(Map.fetch!(definition, "nodes"), fn node ->
      module = Catalog.fetch!(node["type"], node["version"])
      function_exported?(module, :__external_operation__, 0)
    end)
  end

  @doc false
  def start(%Run{} = run, workflow, input, opts) do
    result =
      Repo.transaction(fn ->
        _run = lock_run!(run.id)

        workflow =
          workflow
          |> Workflow.enable_event_emission()
          |> Workflow.plan(Engine.input(input, run.id))

        checkpoint!(run.id, workflow)
        enqueue!(%{run_id: run.id, continuation_key: "start"})
        run
      end)

    with {:ok, run} <- result do
      case Keyword.get(opts, :executor) do
        :inline -> advance(run.id, opts)
        _executor -> {:ok, run}
      end
    end
  end

  @doc "Lists a run's external intent through its organization authorization boundary."
  def list(%Scope{} = scope, run_id) do
    _run = Workflows.get_run!(scope, run_id)

    with :ok <- Authorization.authorize(scope, "workflows:run") do
      operations(run_id)
      |> order_by([operation], asc: operation.inserted_at, asc: operation.id)
      |> Repo.all()
    end
  end

  @doc "Returns one authorized external operation."
  def get(%Scope{} = scope, id) do
    org_id = Scope.organization_id!(scope)

    with :ok <- Authorization.authorize(scope, "workflows:run") do
      case Repo.get_by(ExternalOperation, id: id, org_id: org_id) do
        nil -> {:error, :not_found}
        operation -> {:ok, operation}
      end
    end
  end

  @doc false
  def waiting?(run_id) do
    Repo.exists?(
      from operation in ExternalOperation,
        where: operation.run_id == ^run_id and operation.status != :consumed
    )
  end

  @doc "Replays committed native events and advances a bounded batch of ready work."
  def advance(run_id, opts \\ []) do
    run = Workflows.get_run_for_system!(run_id) |> Repo.preload(:graph)

    case run.status do
      status when status in [:complete, :failed, :cancelled] -> broadcast_completion({:ok, run})
      :running -> advance_running(run, opts)
    end
  end

  defp advance_running(run, opts) do
    run_id = run.id

    with {:ok, scope} <- execution_scope(run),
         {:ok, base} <- Compiler.compile(run.definition),
         {:ok, runtime} <-
           Credentials.resolve_run_context(
             run.definition,
             base,
             Keyword.get(opts, :run_context, %{}),
             Scope.execution_context(scope, run_permissions(run))
           ) do
      Repo.transaction(fn ->
        current = lock_run!(run_id)

        case current.status do
          status when status in [:complete, :failed, :cancelled] ->
            current

          :running ->
            {:ok, events} = PostgresStore.stream(run_id, %{repo: Repo})
            workflow = Replay.restore(events, base) |> unwrap!()

            workflow =
              workflow |> Workflow.put_run_context(runtime) |> Workflow.enable_event_emission()

            drive(current, workflow, @batch_limit)
        end
      end)
      |> broadcast_completion()
    else
      {:error, :execution_actor_ineligible} ->
        Repo.transaction(fn ->
          current = lock_run!(run_id)

          current
          |> Run.changeset(%{
            status: :failed,
            output: nil,
            error: %{"reason" => "execution_actor_ineligible"},
            completed_at: DateTime.utc_now(:second)
          })
          |> Repo.update()
          |> unwrap!()
        end)
        |> broadcast_completion()

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Performs one bounded owner reconciliation outside the graph checkpoint transaction."
  def reconcile(id) do
    operation = Repo.get!(ExternalOperation, id)

    case operation.status do
      :consumed ->
        {:ok, :complete}

      :terminal ->
        with {:ok, _run} <- advance(operation.run_id), do: {:ok, :complete}

      status when status in [:admitted, :waiting] ->
        reconcile_pending(operation)
    end
  end

  defp reconcile_pending(operation) do
    run = Workflows.get_run_for_system!(operation.run_id)

    case run.status do
      :running ->
        reconcile_pending_in_run(operation, run)

      status when status in [:failed, :cancelled] ->
        accept_reconciliation(operation, {:error, %{"reason" => "run_#{status}"}})
    end
  end

  defp reconcile_pending_in_run(operation, run) do
    with {:ok, scope} <-
           Authorization.execution_scope(%ExecutionContext{
             organization_id: operation.org_id,
             actor_user_id: operation.actor_user_id,
             required_permissions: run_permissions(run)
           }) do
      case DateTime.compare(operation.deadline, DateTime.utc_now(:second)) do
        :gt ->
          adapter =
            Application.get_env(:hermitscale, __MODULE__, [])
            |> Keyword.get(:adapter, ExternalOperationAdapter)

          result =
            case operation.status do
              :admitted -> adapter.dispatch(scope, operation)
              :waiting -> adapter.poll(scope, operation)
            end

          accept_reconciliation(operation, result)

        _expired ->
          accept_reconciliation(
            operation,
            {:error, %{"reason" => "external_operation_deadline_exceeded"}}
          )
      end
    else
      {:error, :execution_actor_ineligible} ->
        accept_reconciliation(operation, {:error, %{"reason" => "execution_actor_ineligible"}})

      {:error, _reason} = error ->
        error
    end
  end

  defp accept_reconciliation(operation, {:waiting, resource}) do
    Repo.transaction(fn ->
      current = lock_operation!(operation.id)

      case current.status do
        status when status in [:terminal, :consumed] ->
          :complete

        status when status in [:admitted, :waiting] ->
          current
          |> ExternalOperation.changeset(%{status: :waiting, resource: jsonable(resource)})
          |> Repo.update()
          |> unwrap!()

          :waiting
      end
    end)
  end

  defp accept_reconciliation(operation, {:complete, result}) do
    with {:ok, _operation} <- accept_terminal(operation.id, {:ok, result}), do: {:ok, :complete}
  end

  defp accept_reconciliation(_operation, {:error, reason})
       when reason in [:unavailable, :rate_limited, :provider_unavailable],
       do: {:error, reason}

  defp accept_reconciliation(_operation, {:error, {:provider_request_failed, status} = reason})
       when status == 429 or status >= 500,
       do: {:error, reason}

  defp accept_reconciliation(operation, {:error, reason}) do
    with {:ok, _operation} <- accept_terminal(operation.id, {:error, normalize_error(reason)}),
         do: {:ok, :complete}
  end

  @doc false
  def accept_terminal(id, outcome) do
    {result, error} =
      case outcome do
        {:ok, result} -> {jsonable(result), nil}
        {:error, error} -> {nil, jsonable(error)}
      end

    digest = :crypto.hash(:sha256, Jason.encode!([result, error])) |> Base.encode16(case: :lower)

    Repo.transaction(fn ->
      operation = lock_operation!(id)

      case operation do
        %ExternalOperation{status: status, outcome_digest: ^digest}
        when status in [:terminal, :consumed] ->
          operation

        %ExternalOperation{status: status} when status in [:terminal, :consumed] ->
          Repo.rollback(:terminal_outcome_conflict)

        %ExternalOperation{} ->
          updated =
            operation
            |> ExternalOperation.changeset(%{
              status: :terminal,
              result: result,
              error: error,
              outcome_digest: digest,
              completed_at: DateTime.utc_now(:second)
            })
            |> Repo.update()
            |> unwrap!()

          enqueue!(%{run_id: operation.run_id, continuation_key: operation.id})
          updated
      end
    end)
  end

  @doc false
  def notify(kind, id) do
    ExternalOperation
    |> where([operation], operation.status in [:admitted, :waiting])
    |> where(
      [operation],
      fragment(
        "?->>'kind' = ? AND ?->>'id' = ?",
        operation.resource,
        ^kind,
        operation.resource,
        ^id
      )
    )
    |> Repo.all()
    |> Enum.each(fn operation -> enqueue!(%{operation_id: operation.id}) end)

    :ok
  end

  defp drive(run, workflow, 0) do
    checkpoint!(run.id, workflow)
    current = Repo.get!(Run, run.id)
    count = operations(run.id) |> Repo.aggregate(:count)
    enqueue!(%{run_id: run.id, continuation_key: "#{current.last_event_sequence}:#{count}"})
    Repo.get!(Run, run.id)
  end

  defp drive(run, workflow, budget) do
    pending =
      operations(run.id) |> where([operation], operation.status != :consumed) |> Repo.all()

    case Enum.find(pending, &(&1.status == :terminal)) do
      %ExternalOperation{} = operation ->
        continue_terminal(run, workflow, operation, budget)

      nil ->
        reserved = MapSet.new(pending, &{&1.node_identity, &1.input_identity})

        {workflow, runnables} =
          Workflow.prepare_for_dispatch(workflow,
            limit: 1,
            exclude: fn activation ->
              MapSet.member?(
                reserved,
                {to_string(activation.node_hash), to_string(activation.fact_hash)}
              )
            end
          )

        case runnables do
          [runnable] -> execute_ready(run, workflow, runnable, budget)
          [] -> idle(run, workflow, pending)
        end
    end
  end

  defp execute_ready(run, workflow, runnable, budget) do
    case Node.external?(runnable.node) and Metadata.state(runnable.input_fact.meta).status == :ok do
      true ->
        case Node.external_request(runnable) do
          {:ok, request} ->
            {_operation, workflow} = admit!(run, workflow, runnable, request)
            drive(run, workflow, budget - 1)

          {:error, error} ->
            fail_run!(run, workflow, %{
              "reason" => "external_operation_parameter_error",
              "node" => runnable.node.name,
              "details" => Exception.message(error)
            })
        end

      false ->
        policy = SchedulerPolicy.resolve(runnable, workflow.scheduler_policies)
        executed = PolicyDriver.execute(runnable, policy)

        case executed.status do
          :completed ->
            drive(run, Workflow.apply_runnable(workflow, executed), budget - 1)

          :skipped ->
            drive(run, Workflow.apply_runnable(workflow, executed), budget - 1)

          :failed ->
            fail_run!(run, workflow, %{
              "reason" => "node_execution_failed",
              "node" => runnable.node.name,
              "details" => inspect(executed.error, limit: 10)
            })
        end
    end
  end

  defp admit!(run, workflow, runnable, params) do
    request = jsonable(params)
    callback = Runic.Workflow.SingleOutput.Context.from_runnable(runnable)

    context =
      Hermitscale.Workflows.Engine.Context.new(
        runnable.input_fact.value,
        runnable.input_fact.meta,
        callback,
        runnable.input_fact.hash
      )

    deadline_seconds = Map.get(request, "timeout_seconds", 3600) |> min(3600) |> max(30)

    operation =
      %ExternalOperation{
        run_id: run.id,
        org_id: run.graph.org_id,
        actor_user_id: run.execution_actor_user_id,
        node_id: runnable.node.name,
        node_type: runnable.node.module.__catalog_node__().id,
        definition_identity:
          Replay.definition_event(Compiler.compile!(run.definition)).fingerprint
          |> Base.encode16(case: :lower),
        node_identity: to_string(runnable.node.hash),
        input_identity: to_string(runnable.input_fact.hash),
        activation_identity: to_string(runnable.activation_id),
        lineage: %{
          "root_id" => to_string(context.root_id),
          "ancestry" => Hermitscale.Workflows.Engine.Context.expressions(context)["ancestry"]
        },
        request: request,
        deadline: DateTime.add(DateTime.utc_now(:second), deadline_seconds, :second)
      }
      |> ExternalOperation.changeset(%{})
      |> Repo.insert()
      |> unwrap!()

    workflow = checkpoint!(run.id, workflow)
    enqueue!(%{operation_id: operation.id})
    {operation, workflow}
  end

  defp continue_terminal(run, workflow, operation, budget) do
    {workflow, runnables} =
      Workflow.prepare_for_dispatch(workflow,
        limit: 1,
        exclude: fn activation ->
          {to_string(activation.node_hash), to_string(activation.fact_hash)} !=
            {operation.node_identity, operation.input_identity}
        end
      )

    [runnable] = runnables
    true = to_string(runnable.activation_id) == operation.activation_identity

    true =
      Replay.definition_event(Compiler.compile!(run.definition)).fingerprint
      |> Base.encode16(case: :lower) == operation.definition_identity

    outcome =
      case operation.error do
        nil -> operation.result
        error -> Result.failure(error)
      end

    executed = Node.complete_external(runnable, outcome)
    workflow = Workflow.apply_runnable(workflow, executed)
    workflow = checkpoint!(run.id, workflow)

    operation
    |> ExternalOperation.changeset(%{status: :consumed, consumed_at: DateTime.utc_now(:second)})
    |> Repo.update()
    |> unwrap!()

    case executed.status do
      :completed ->
        drive(run, workflow, budget - 1)

      :failed ->
        fail_run!(run, workflow, %{
          "reason" => "external_operation_failed",
          "node" => operation.node_id,
          "operation_id" => operation.id,
          "details" => operation.error
        })
    end
  end

  defp idle(run, workflow, [_operation | _pending]) do
    checkpoint!(run.id, workflow)
    Repo.get!(Run, run.id)
  end

  defp idle(run, workflow, []) do
    case {Enum.empty?(Enum.to_list(Workflow.activation_descriptors(workflow))),
          Engine.completion(workflow)} do
      {true, :ok} ->
        consumed = MapSet.new(run.definition["connections"], & &1["from"])

        output =
          run.definition["nodes"]
          |> Enum.reject(&MapSet.member?(consumed, &1["id"]))
          |> Map.new(&{&1["id"], Engine.productions(workflow, &1["id"])})

        checkpoint!(run.id, workflow)

        run
        |> Run.changeset(%{
          status: :complete,
          output: %{"value" => jsonable(output)},
          completed_at: DateTime.utc_now(:second)
        })
        |> Repo.update()
        |> unwrap!()

      {true, {:error, error}} ->
        fail_run!(run, workflow, error)

      {false, _completion} ->
        drive(run, workflow, @batch_limit - 1)
    end
  end

  defp fail_run!(run, workflow, error) do
    checkpoint!(run.id, workflow)

    run
    |> Run.changeset(%{
      status: :failed,
      output: nil,
      error: error,
      completed_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
    |> unwrap!()
  end

  defp checkpoint!(run_id, workflow) do
    events = Enum.reverse(workflow.uncommitted_events)
    {:ok, _cursor} = PostgresStore.append(run_id, events, %{repo: Repo})
    %{workflow | uncommitted_events: []}
  end

  defp lock_run!(id),
    do:
      Run
      |> where([run], run.id == ^id)
      |> lock("FOR UPDATE")
      |> Repo.one!()
      |> Repo.preload(:graph)

  defp lock_operation!(id),
    do:
      ExternalOperation
      |> where([operation], operation.id == ^id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

  defp operations(run_id),
    do: from(operation in ExternalOperation, where: operation.run_id == ^run_id)

  defp execution_scope(run) do
    Authorization.execution_scope(%ExecutionContext{
      organization_id: run.graph.org_id,
      actor_user_id: run.execution_actor_user_id,
      required_permissions: run_permissions(run)
    })
  end

  defp run_permissions(%Run{trigger_id: nil}), do: ["workflows:run"]

  defp run_permissions(%Run{input: input}) do
    case get_in(input, ["value", "trigger", "mode"]) do
      "manual" -> ["workflows:run"]
      _unattended -> ["workflows:run", "workflows:activate"]
    end
  end

  defp enqueue!(args), do: args |> ExternalOperationWorker.new() |> Oban.insert() |> unwrap!()
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
  defp jsonable(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp normalize_error(%Ecto.Changeset{} = changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, fn {message, _options} -> message end)
    %{"reason" => "invalid_external_operation_request", "errors" => jsonable(errors)}
  end

  defp normalize_error(error) when is_map(error) and not is_struct(error), do: error
  defp normalize_error(error), do: %{"reason" => inspect(error, limit: 10)}

  defp broadcast_completion({:ok, %Run{status: status} = run} = result)
       when status in [:complete, :failed] do
    :ok = Workflows.broadcast_run_result(run)
    result
  end

  defp broadcast_completion(result), do: result
end
