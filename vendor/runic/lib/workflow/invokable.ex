defprotocol Runic.Workflow.Invokable do
  @moduledoc """
  Protocol defining how workflow nodes execute within a workflow context.

  The `Invokable` protocol is the runtime heart of Runic. It defines how each node type
  (Step, Condition, Rule, Accumulator, etc.) executes within the context of a workflow,
  enabling extension of Runic's runtime with nodes that have different execution properties
  and evaluation semantics.

  ## Three-Phase Execution Model

  All workflow execution uses a three-phase model that enables parallel execution
  and external scheduler integration:

  ```
  ┌─────────────┐      ┌─────────────┐      ┌─────────────┐
  │   PREPARE   │ ───► │   EXECUTE   │ ───► │    APPLY    │
  │  (Phase 1)  │      │  (Phase 2)  │      │  (Phase 3)  │
  └─────────────┘      └─────────────┘      └─────────────┘
        │                    │                    │
        ▼                    ▼                    ▼
   Extract context      Run work fn         Reduce results
   from workflow        in isolation         into workflow
   → %Runnable{}        (parallelizable)     (sequential)
  ```

  1. **Prepare** (`prepare/3`) - Extract minimal context from workflow into a `%Runnable{}` struct
  2. **Execute** (`execute/2`) - Run the node's work function in isolation (can be parallelized)
  3. **Apply** - Events on the Runnable are folded back into the workflow via `apply_event/2`

  This separation enables:

  - **Parallel execution** of independent nodes (Phase 2 has no workflow access)
  - **External scheduler integration** via `prepare_for_dispatch/1` and `apply_runnable/2`
  - **Distributed execution** by dispatching Runnables to remote workers (events are serializable)
  - **Separation of concerns** between pure computation and stateful workflow updates

  ## Protocol Functions

  | Function | Purpose |
  |----------|---------|
  | `match_or_execute/1` | Declares whether node is a `:match` (predicate) or `:execute` (produces facts) |
  | `invoke/3` | High-level API that runs all three phases internally |
  | `prepare/3` | Phase 1: Extract context from workflow, build a `%Runnable{}` |
  | `execute/2` | Phase 2: Run the work function using only Runnable context |

  ## Return Types

  - `prepare/3` returns:
    - `{:ok, %Runnable{}}` - Ready for execution
    - `{:skip, (Workflow.t() -> Workflow.t())}` - Skip with reducer function
    - `{:defer, (Workflow.t() -> Workflow.t())}` - Defer with reducer function

  - `execute/2` returns a `%Runnable{}` with:
    - `status: :completed` - With `result` and `events` populated
    - `status: :failed` - With `error` populated
    - `status: :skipped` - With `events` for skip handling

  ## Built-in Implementations

  Runic provides `Invokable` implementations for all core node types:

  | Node Type | Match/Execute | Description |
  |-----------|---------------|-------------|
  | `Runic.Workflow.Root` | `:match` | Entry point for facts into the workflow |
  | `Runic.Workflow.Condition` | `:match` | Boolean predicate check |
  | `Runic.Workflow.Step` | `:execute` | Transform input fact to output fact |
  | `Runic.Workflow.Conjunction` | `:match` | Logical AND of multiple conditions |
  | `Runic.Workflow.Accumulator` | `:execute` | Stateful reducer across invocations |
  | `Runic.Workflow.Join` | `:execute` | Wait for multiple parent facts before firing |
  | `Runic.Workflow.FanOut` | `:execute` | Spread enumerable into parallel branches |
  | `Runic.Workflow.FanIn` | `:execute` | Collect parallel results back together |

  ## External Scheduler Integration

  The three-phase model enables integration with custom schedulers:

      # Phase 1: Prepare runnables for dispatch
      workflow = Workflow.plan_eagerly(workflow, input)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      # Phase 2: Execute (dispatch to worker pool, external service, etc.)
      executed = Task.async_stream(runnables, fn runnable ->
        Runic.Workflow.Invokable.execute(runnable.node, runnable)
      end, timeout: :infinity)

      # Phase 3: Apply results back to workflow
      workflow = Enum.reduce(executed, workflow, fn {:ok, runnable}, wrk ->
        Workflow.apply_runnable(wrk, runnable)
      end)

  ## Implementing Custom Invokable

  To create a custom node type, implement the protocol:

      defmodule MyApp.CustomNode do
        defstruct [:hash, :name, :work]
      end

      defimpl Runic.Workflow.Invokable, for: MyApp.CustomNode do
        alias Runic.Workflow
        alias Runic.Workflow.{Fact, Runnable, CausalContext}
        alias Runic.Workflow.Events.{FactProduced, ActivationConsumed}

        def match_or_execute(_node), do: :execute

        def invoke(%MyApp.CustomNode{} = node, workflow, fact) do
          result = node.work.(fact.value)
          result_fact = Fact.new(value: result, ancestry: {node.hash, fact.hash})

          workflow
          |> Workflow.log_fact(result_fact)
          |> Workflow.draw_connection(node, result_fact, :produced)
          |> Workflow.mark_runnable_as_ran(node, fact)
          |> Workflow.prepare_next_runnables(node, result_fact)
        end

        def prepare(%MyApp.CustomNode{} = node, workflow, fact) do
          context = CausalContext.new(
            node_hash: node.hash,
            input_fact: fact,
            ancestry_depth: Workflow.ancestry_depth(workflow, fact)
          )

          {:ok, Runnable.new(node, fact, context)}
        end

        def execute(%MyApp.CustomNode{} = node, %Runnable{input_fact: fact, context: ctx} = runnable) do
          result = node.work.(fact.value)
          result_fact = Fact.new(value: result, ancestry: {node.hash, fact.hash})

          events = [
            %FactProduced{
              hash: result_fact.hash,
              value: result_fact.value,
              ancestry: result_fact.ancestry,
              producer_label: :produced,
              weight: ctx.ancestry_depth + 1
            },
            %ActivationConsumed{
              fact_hash: fact.hash,
              node_hash: node.hash,
              from_label: :runnable
            }
          ]

          Runnable.complete(runnable, result_fact, events)
        end
      end

  See the [Protocols Guide](protocols.html) for more details and examples.
  """

  alias Runic.Workflow.Runnable

  @doc """
  Returns whether this node is a match (predicate/gate) or execute (produces facts) node.
  """
  @spec match_or_execute(node :: struct()) :: :match | :execute
  def match_or_execute(node)

  @doc """
  Legacy invoke function - activates a node in context of a workflow and input fact.
  Returns a new workflow with the node's effects applied.

  During migration, this may delegate to the three-phase prepare/execute/apply cycle.
  """
  @spec invoke(node :: struct(), workflow :: Runic.Workflow.t(), fact :: Runic.Workflow.Fact.t()) ::
          Runic.Workflow.t()
  def invoke(node, workflow, fact)

  @doc """
  Phase 1: Prepare a runnable for execution.

  Extracts minimal context from the workflow needed to execute this node.
  Returns a `%Runnable{}` struct that can be executed independently of the workflow.

  ## Returns

  - `{:ok, %Runnable{}}` - Node is ready for execution
  - `{:skip, reducer_fn}` - Node should be skipped, apply reducer to workflow
  - `{:defer, reducer_fn}` - Node should be deferred, apply reducer to workflow
  """
  @spec prepare(
          node :: struct(),
          workflow :: Runic.Workflow.t(),
          fact :: Runic.Workflow.Fact.t()
        ) ::
          {:ok, Runnable.t()}
          | {:skip, (Runic.Workflow.t() -> Runic.Workflow.t())}
          | {:defer, (Runic.Workflow.t() -> Runic.Workflow.t())}
  def prepare(node, workflow, fact)

  @doc """
  Phase 2: Execute a prepared runnable.

  Runs the node's work function using only the context captured in the Runnable.
  No workflow access is allowed during this phase (enables parallelization).

  Returns the Runnable with:
  - `status` updated to `:completed`, `:failed`, or `:skipped`
  - `result` populated with the execution result
  - `events` populated with event structs to fold into the workflow
  """
  @spec execute(node :: struct(), runnable :: Runnable.t()) :: Runnable.t()
  def execute(node, runnable)
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Root do
  alias Runic.Workflow.Root
  alias Runic.Workflow.Fact
  alias Runic.Workflow
  alias Runic.Workflow.{Runnable, CausalContext}
  alias Runic.Workflow.Events.FactProduced

  def match_or_execute(_root), do: :match

  def invoke(%Root{} = root, workflow, fact) do
    workflow
    |> Workflow.log_fact(fact)
    |> Workflow.prepare_next_runnables(root, fact)
  end

  def prepare(%Root{} = root, _workflow, %Fact{} = fact) do
    context =
      CausalContext.new(
        node_hash: nil,
        input_fact: fact,
        ancestry_depth: 0
      )

    {:ok, Runnable.new(nil, root, fact, context)}
  end

  def execute(%Root{} = _root, %Runnable{input_fact: fact} = runnable) do
    events = [
      %FactProduced{
        hash: fact.hash,
        value: fact.value,
        ancestry: fact.ancestry,
        producer_label: :input,
        weight: 0
      }
    ]

    Runnable.complete(runnable, fact, events)
  end
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Condition do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Condition,
    Runnable,
    CausalContext,
    HookRunner
  }

  alias Runic.Workflow.Events.{ConditionSatisfied, ActivationConsumed}

  def match_or_execute(_condition), do: :match

  def invoke(
        %Condition{} = condition,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    if Condition.check(condition, fact) do
      workflow
      |> Workflow.prepare_next_runnables(condition, fact)
      |> Workflow.draw_connection(fact, condition, :satisfied)
      |> Workflow.mark_runnable_as_ran(condition, fact)
      |> Workflow.run_after_hooks(condition, fact)
    else
      workflow
      |> Workflow.mark_runnable_as_ran(condition, fact)
      |> Workflow.run_after_hooks(condition, fact)
    end
  end

  def prepare(%Condition{} = condition, %Workflow{} = workflow, %Fact{} = fact) do
    meta_context =
      if Condition.has_meta_refs?(condition) do
        Workflow.prepare_meta_context(workflow, condition)
      else
        %{}
      end

    run_context = Workflow.get_run_context(workflow, condition.name)

    context =
      CausalContext.new(
        node_hash: condition.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        hooks: Workflow.get_hooks(workflow, condition.hash),
        meta_context: meta_context,
        run_context: run_context
      )

    {:ok, Runnable.new(condition, fact, context)}
  end

  def execute(%Condition{} = condition, %Runnable{input_fact: fact, context: ctx} = runnable) do
    with {:ok, before_apply_fns} <- HookRunner.run_before(ctx, condition, fact) do
      effective_context = merge_effective_context(ctx.meta_context, ctx.run_context)

      satisfied =
        if effective_context != %{} and condition.arity == 2 do
          Condition.check_with_meta_context(condition, fact, effective_context)
        else
          Condition.check(condition, fact)
        end

      case HookRunner.run_after(ctx, condition, fact, satisfied) do
        {:ok, after_apply_fns} ->
          events =
            if satisfied do
              [
                %ConditionSatisfied{
                  fact_hash: fact.hash,
                  condition_hash: condition.hash,
                  weight: ctx.ancestry_depth + 1
                },
                %ActivationConsumed{
                  fact_hash: fact.hash,
                  node_hash: condition.hash,
                  from_label: :matchable
                }
              ]
            else
              [
                %ActivationConsumed{
                  fact_hash: fact.hash,
                  node_hash: condition.hash,
                  from_label: :matchable
                }
              ]
            end

          hook_fns = before_apply_fns ++ after_apply_fns
          Runnable.complete(runnable, satisfied, events, hook_fns)

        {:error, reason} ->
          Runnable.fail(runnable, {:hook_error, reason})
      end
    else
      {:error, reason} ->
        Runnable.fail(runnable, {:hook_error, reason})
    end
  end

  defp merge_effective_context(meta, run) when map_size(meta) == 0 and map_size(run) == 0, do: %{}
  defp merge_effective_context(meta, run) when map_size(run) == 0, do: meta
  defp merge_effective_context(meta, run) when map_size(meta) == 0, do: run
  defp merge_effective_context(meta, run), do: Map.merge(run, meta)
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Step do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Step,
    Components,
    Runnable,
    CausalContext,
    HookRunner
  }

  alias Runic.Workflow.Events.{FactProduced, ActivationConsumed}

  def match_or_execute(_step), do: :execute

  def invoke(
        %Step{} = step,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    result = Components.run(step.work, fact.value, Components.arity_of(step.work))

    result_fact = Fact.new(value: result, ancestry: {step.hash, fact.hash})

    causal_depth = Workflow.ancestry_depth(workflow, fact) + 1

    workflow
    |> Workflow.log_fact(result_fact)
    |> Workflow.draw_connection(step, result_fact, :produced, weight: causal_depth)
    |> Workflow.mark_runnable_as_ran(step, fact)
    |> Workflow.run_after_hooks(step, result_fact)
    |> Workflow.prepare_next_runnables(step, result_fact)
  end

  def prepare(%Step{} = step, %Workflow{} = workflow, %Fact{} = fact) do
    meta_context =
      if Step.has_meta_refs?(step) do
        Workflow.prepare_meta_context(workflow, step)
      else
        %{}
      end

    run_context = Workflow.get_run_context(workflow, step.name)

    context =
      CausalContext.new(
        node_hash: step.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        hooks: Workflow.get_hooks(workflow, step.hash),
        meta_context: meta_context,
        run_context: run_context
      )

    {:ok, Runnable.new(step, fact, context)}
  end

  def execute(%Step{} = step, %Runnable{input_fact: fact, context: ctx} = runnable) do
    with {:ok, before_apply_fns} <- HookRunner.run_before(ctx, step, fact) do
      try do
        result = run_step_work(step, fact.value, ctx)

        result_fact = Fact.new(value: result, ancestry: {step.hash, fact.hash})

        case HookRunner.run_after(ctx, step, fact, result_fact) do
          {:ok, after_apply_fns} ->
            events = build_events(step, fact, result_fact, ctx)
            hook_fns = before_apply_fns ++ after_apply_fns
            Runnable.complete(runnable, result_fact, events, hook_fns)

          {:error, reason} ->
            Runnable.fail(runnable, {:hook_error, reason})
        end
      rescue
        e ->
          Runnable.fail(runnable, e)
      end
    else
      {:error, reason} ->
        Runnable.fail(runnable, {:hook_error, reason})
    end
  end

  defp run_step_work(step, input, ctx) do
    effective_context = merge_effective_context(ctx.meta_context, ctx.run_context)
    arity = Components.arity_of(step.work)

    cond do
      effective_context != %{} and arity >= 2 ->
        step.work.(input, effective_context)

      Step.has_meta_refs?(step) and ctx.meta_context != %{} ->
        Step.run_with_meta_context(step, input, ctx.meta_context)

      true ->
        Components.run(step.work, input, arity)
    end
  end

  defp merge_effective_context(meta, run) when map_size(meta) == 0 and map_size(run) == 0, do: %{}
  defp merge_effective_context(meta, run) when map_size(run) == 0, do: meta
  defp merge_effective_context(meta, run) when map_size(meta) == 0, do: run
  defp merge_effective_context(meta, run), do: Map.merge(run, meta)

  defp build_events(step, input_fact, result_fact, ctx) do
    [
      %FactProduced{
        hash: result_fact.hash,
        value: result_fact.value,
        ancestry: result_fact.ancestry,
        producer_label: :produced,
        weight: ctx.ancestry_depth + 1
      },
      %ActivationConsumed{
        fact_hash: input_fact.hash,
        node_hash: step.hash,
        from_label: :runnable
      }
    ]
  end

end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Conjunction do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Conjunction,
    Runnable,
    CausalContext
  }

  alias Runic.Workflow.Events.{ConditionSatisfied, ActivationConsumed}

  def match_or_execute(_conjunction), do: :match

  def invoke(
        %Conjunction{} = conj,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    satisfied_conditions = Workflow.satisfied_condition_hashes(workflow, fact)

    causal_depth = Workflow.ancestry_depth(workflow, fact) + 1

    if conj.hash not in satisfied_conditions and
         Enum.all?(conj.condition_hashes, &(&1 in satisfied_conditions)) do
      workflow
      |> Workflow.prepare_next_runnables(conj, fact)
      |> Workflow.draw_connection(fact, conj, :satisfied, weight: causal_depth)
      |> Workflow.mark_runnable_as_ran(conj, fact)
    else
      Workflow.mark_runnable_as_ran(workflow, conj, fact)
    end
  end

  def prepare(%Conjunction{} = conj, %Workflow{} = workflow, %Fact{} = fact) do
    satisfied_conditions = Workflow.satisfied_condition_hashes(workflow, fact)

    context =
      CausalContext.new(
        node_hash: conj.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        satisfied_conditions: MapSet.new(satisfied_conditions)
      )

    {:ok, Runnable.new(conj, fact, context)}
  end

  def execute(%Conjunction{} = conj, %Runnable{input_fact: fact, context: ctx} = runnable) do
    satisfied_conditions = ctx.satisfied_conditions

    all_satisfied =
      conj.hash not in satisfied_conditions and
        Enum.all?(conj.condition_hashes, &(&1 in satisfied_conditions))

    events =
      if all_satisfied do
        [
          %ConditionSatisfied{
            fact_hash: fact.hash,
            condition_hash: conj.hash,
            weight: ctx.ancestry_depth + 1
          },
          %ActivationConsumed{
            fact_hash: fact.hash,
            node_hash: conj.hash,
            from_label: :matchable
          }
        ]
      else
        [
          %ActivationConsumed{
            fact_hash: fact.hash,
            node_hash: conj.hash,
            from_label: :matchable
          }
        ]
      end

    Runnable.complete(runnable, all_satisfied, events)
  end
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Accumulator do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Components,
    Accumulator,
    Runnable,
    CausalContext,
    HookRunner
  }

  alias Runic.Workflow.Events.{FactProduced, ActivationConsumed, StateInitiated}

  def match_or_execute(_state_reactor), do: :execute

  def invoke(
        %Accumulator{} = acc,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    last_known_state = last_known_state(workflow, acc)

    causal_depth = Workflow.ancestry_depth(workflow, fact) + 1

    unless is_nil(last_known_state) do
      next_state = apply(acc.reducer, [fact.value, last_known_state.value])

      next_state_produced_fact = Fact.new(value: next_state, ancestry: {acc.hash, fact.hash})

      workflow
      |> Workflow.log_fact(next_state_produced_fact)
      |> Workflow.draw_connection(acc, fact, :state_produced, weight: causal_depth)
      |> Workflow.mark_runnable_as_ran(acc, fact)
      |> Workflow.run_after_hooks(acc, next_state_produced_fact)
      |> Workflow.prepare_next_runnables(acc, next_state_produced_fact)
    else
      init_fact = init_fact(acc)

      next_state = apply(acc.reducer, [fact.value, init_fact.value])

      next_state_produced_fact = Fact.new(value: next_state, ancestry: {acc.hash, fact.hash})

      workflow
      |> Workflow.log_fact(init_fact)
      |> Workflow.draw_connection(acc, init_fact, :state_initiated, weight: causal_depth)
      |> Workflow.log_fact(next_state_produced_fact)
      |> Workflow.draw_connection(acc, next_state_produced_fact, :state_produced,
        weight: causal_depth
      )
      |> Workflow.mark_runnable_as_ran(acc, fact)
      |> Workflow.run_after_hooks(acc, next_state_produced_fact)
      |> Workflow.prepare_next_runnables(acc, next_state_produced_fact)
    end
  end

  def prepare(%Accumulator{} = acc, %Workflow{} = workflow, %Fact{} = fact) do
    last_state_fact = last_known_state(workflow, acc)

    meta_context =
      if Accumulator.has_meta_refs?(acc) do
        Workflow.prepare_meta_context(workflow, acc)
      else
        %{}
      end

    run_context = Workflow.get_run_context(workflow, acc.name)

    context =
      CausalContext.new(
        node_hash: acc.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        hooks: Workflow.get_hooks(workflow, acc.hash),
        last_known_state: if(last_state_fact, do: last_state_fact.value, else: nil),
        is_state_initialized: not is_nil(last_state_fact),
        mergeable: acc.mergeable,
        meta_context: meta_context,
        run_context: run_context
      )

    {:ok, Runnable.new(acc, fact, context)}
  end

  def execute(%Accumulator{} = acc, %Runnable{input_fact: fact, context: ctx} = runnable) do
    with {:ok, before_apply_fns} <- HookRunner.run_before(ctx, acc, fact) do
      if ctx.is_state_initialized do
        next_state = run_accumulator_reducer(acc, fact.value, ctx.last_known_state, ctx)
        next_state_produced_fact = Fact.new(value: next_state, ancestry: {acc.hash, fact.hash})

        case HookRunner.run_after(ctx, acc, fact, next_state_produced_fact) do
          {:ok, after_apply_fns} ->
            events = [
              %FactProduced{
                hash: next_state_produced_fact.hash,
                value: next_state_produced_fact.value,
                ancestry: next_state_produced_fact.ancestry,
                producer_label: :state_produced,
                weight: ctx.ancestry_depth + 1
              },
              %ActivationConsumed{
                fact_hash: fact.hash,
                node_hash: acc.hash,
                from_label: :runnable
              }
            ]

            hook_fns = before_apply_fns ++ after_apply_fns
            Runnable.complete(runnable, next_state_produced_fact, events, hook_fns)

          {:error, reason} ->
            Runnable.fail(runnable, {:hook_error, reason})
        end
      else
        init_fact_val = acc.init.()

        init_fact =
          Fact.new(
            value: init_fact_val,
            ancestry: {acc.hash, Components.fact_hash(init_fact_val)}
          )

        next_state = run_accumulator_reducer(acc, fact.value, init_fact_val, ctx)
        next_state_produced_fact = Fact.new(value: next_state, ancestry: {acc.hash, fact.hash})

        case HookRunner.run_after(ctx, acc, fact, next_state_produced_fact) do
          {:ok, after_apply_fns} ->
            events = [
              %StateInitiated{
                accumulator_hash: acc.hash,
                init_fact_hash: init_fact.hash,
                init_value: init_fact.value,
                init_ancestry: init_fact.ancestry,
                weight: ctx.ancestry_depth + 1
              },
              %FactProduced{
                hash: next_state_produced_fact.hash,
                value: next_state_produced_fact.value,
                ancestry: next_state_produced_fact.ancestry,
                producer_label: :state_produced,
                weight: ctx.ancestry_depth + 1
              },
              %ActivationConsumed{
                fact_hash: fact.hash,
                node_hash: acc.hash,
                from_label: :runnable
              }
            ]

            hook_fns = before_apply_fns ++ after_apply_fns
            Runnable.complete(runnable, next_state_produced_fact, events, hook_fns)

          {:error, reason} ->
            Runnable.fail(runnable, {:hook_error, reason})
        end
      end
    else
      {:error, reason} ->
        Runnable.fail(runnable, {:hook_error, reason})
    end
  end

  defp last_known_state(workflow, accumulator) do
    Workflow.latest_state_fact(workflow, accumulator)
  end

  defp init_fact(%Accumulator{init: init, hash: hash}) do
    init = init.()
    Fact.new(value: init, ancestry: {hash, Components.fact_hash(init)})
  end

  defp run_accumulator_reducer(acc, value, state, ctx) do
    effective_context = merge_effective_context(ctx.meta_context, ctx.run_context)
    arity = Function.info(acc.reducer, :arity) |> elem(1)

    if effective_context != %{} and arity == 3 do
      acc.reducer.(value, state, effective_context)
    else
      apply(acc.reducer, [value, state])
    end
  end

  defp merge_effective_context(meta, run) when map_size(meta) == 0 and map_size(run) == 0, do: %{}
  defp merge_effective_context(meta, run) when map_size(run) == 0, do: meta
  defp merge_effective_context(meta, run) when map_size(meta) == 0, do: run
  defp merge_effective_context(meta, run), do: Map.merge(run, meta)
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Join do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Join,
    Runnable,
    CausalContext
  }

  alias Runic.Workflow.Events.{JoinFactReceived, ActivationConsumed}

  def match_or_execute(_join), do: :execute

  def invoke(
        %Join{} = join,
        %Workflow{} = workflow,
        %Fact{ancestry: {_parent_hash, _value_hash}} = fact
      ) do
    causal_depth = Workflow.ancestry_depth(workflow, fact) + 1

    workflow =
      Workflow.draw_connection(workflow, fact, join, :joined, weight: causal_depth)

    join_order_weights =
      join.joins
      |> Enum.with_index()
      |> Map.new()

    joined_edges =
      workflow.graph
      |> Multigraph.in_edges(join)
      |> Enum.filter(&(&1.label == :joined))

    possible_priors_by_parent =
      joined_edges
      |> Enum.reduce(%{}, fn edge, acc ->
        parent_hash = elem(edge.v1.ancestry, 0)

        if Map.has_key?(join_order_weights, parent_hash) and not Map.has_key?(acc, parent_hash) do
          Map.put(acc, parent_hash, edge.v1)
        else
          acc
        end
      end)

    possible_priors =
      join.joins
      |> Enum.map(&Map.get(possible_priors_by_parent, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.value)

    if Enum.count(join.joins) == Enum.count(possible_priors) do
      join_bindings_fact = Fact.new(value: possible_priors, ancestry: {join.hash, fact.hash})

      workflow =
        workflow
        |> Workflow.log_fact(join_bindings_fact)
        |> Workflow.prepare_next_runnables(join, join_bindings_fact)

      workflow.graph
      |> Multigraph.in_edges(join)
      |> Enum.filter(&(&1.label in [:runnable, :joined]))
      |> Enum.reduce(workflow, fn
        %{v1: v1, label: :runnable}, %Workflow{} = wrk ->
          Workflow.mark_runnable_as_ran(wrk, join, v1)

        %{v1: v1, v2: v2, label: :joined}, %Workflow{} = wrk ->
          %Workflow{
            wrk
            | graph:
                wrk.graph
                |> Multigraph.update_labelled_edge(v1, v2, :joined, label: :join_satisfied)
          }
      end)
      |> Workflow.draw_connection(join, join_bindings_fact, :produced, weight: causal_depth)
      |> Workflow.run_after_hooks(join, join_bindings_fact)
    else
      Workflow.mark_runnable_as_ran(workflow, join, fact)
    end
  end

  def prepare(%Join{} = join, %Workflow{} = workflow, %Fact{} = fact) do
    join_order_weights =
      join.joins
      |> Enum.with_index()
      |> Map.new()

    # Get current join state from graph
    joined_edges =
      workflow.graph
      |> Multigraph.in_edges(join)
      |> Enum.filter(&(&1.label == :joined))

    # Collect satisfied facts by parent
    satisfied_by_parent =
      joined_edges
      |> Enum.reduce(%{}, fn edge, acc ->
        parent_hash = elem(edge.v1.ancestry, 0)

        if Map.has_key?(join_order_weights, parent_hash) and not Map.has_key?(acc, parent_hash) do
          Map.put(acc, parent_hash, edge.v1)
        else
          acc
        end
      end)

    # Check if adding this fact would complete the join
    current_fact_parent = elem(fact.ancestry, 0)

    satisfied_with_current =
      if Map.has_key?(join_order_weights, current_fact_parent) do
        Map.put(satisfied_by_parent, current_fact_parent, fact)
      else
        satisfied_by_parent
      end

    would_complete = map_size(satisfied_with_current) >= length(join.joins)

    # Collect values in order if would complete
    collected_values =
      if would_complete do
        join.joins
        |> Enum.map(&Map.get(satisfied_with_current, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(& &1.value)
      else
        nil
      end

    context =
      CausalContext.new(
        node_hash: join.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        hooks: Workflow.get_hooks(workflow, join.hash),
        join_context: %{
          joins: join.joins,
          satisfied: satisfied_by_parent,
          would_complete: would_complete,
          values: collected_values
        }
      )

    {:ok, Runnable.new(join, fact, context)}
  end

  def execute(%Join{} = _join, %Runnable{input_fact: fact, context: ctx} = runnable) do
    parent_hash = elem(fact.ancestry, 0)

    events = [
      %JoinFactReceived{
        fact_hash: fact.hash,
        join_hash: ctx.node_hash,
        parent_hash: parent_hash,
        weight: ctx.ancestry_depth + 1
      },
      %ActivationConsumed{
        fact_hash: fact.hash,
        node_hash: ctx.node_hash,
        from_label: :runnable
      }
    ]

    Runnable.complete(runnable, :waiting, events)
  end
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.FanOut do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    FanOut,
    Runnable,
    Components,
    CausalContext
  }

  alias Runic.Workflow.Events.{FactProduced, ActivationConsumed}

  def match_or_execute(_fan_out), do: :execute

  # Build a per-element fact. The index is folded into the hash so duplicate
  # element values stay distinct vertices, and stamped in `meta` (with the
  # source scatter and batch size) so a downstream FanIn can reduce in
  # deterministic emission order and detect completion structurally.
  defp scatter_fact(fan_out, source_fact, value, index, of) do
    ancestry = {fan_out.hash, source_fact.hash}

    Fact.new(
      hash: Components.fact_hash({value, ancestry, index}),
      value: value,
      ancestry: ancestry,
      meta: %{scatter: fan_out.hash, index: index, of: of}
    )
  end

  def invoke(
        %FanOut{} = fan_out,
        %Workflow{} = workflow,
        %Fact{} = source_fact
      ) do
    unless is_nil(Enumerable.impl_for(source_fact.value)) do
      causal_depth = Workflow.ancestry_depth(workflow, source_fact) + 1
      elements = Enum.to_list(source_fact.value)
      of = length(elements)

      elements
      |> Enum.with_index()
      |> Enum.reduce(workflow, fn {value, index}, wrk ->
        fact = scatter_fact(fan_out, source_fact, value, index, of)

        wrk
        |> Workflow.log_fact(fact)
        |> Workflow.prepare_next_runnables(fan_out, fact)
        |> Workflow.draw_connection(fan_out, fact, :fan_out, weight: causal_depth)
      end)
      |> Workflow.mark_runnable_as_ran(fan_out, source_fact)
    else
      Workflow.mark_runnable_as_ran(workflow, fan_out, source_fact)
    end
  end

  def prepare(%FanOut{} = fan_out, %Workflow{} = workflow, %Fact{} = fact) do
    if is_nil(Enumerable.impl_for(fact.value)) do
      {:skip, fn wf -> Workflow.mark_runnable_as_ran(wf, fan_out, fact) end}
    else
      context =
        CausalContext.new(
          node_hash: fan_out.hash,
          input_fact: fact,
          ancestry_depth: Workflow.ancestry_depth(workflow, fact)
        )

      {:ok, Runnable.new(fan_out, fact, context)}
    end
  end

  def execute(%FanOut{} = fan_out, %Runnable{input_fact: source_fact, context: ctx} = runnable) do
    elements = Enum.to_list(source_fact.value)
    of = length(elements)

    emitted_facts =
      elements
      |> Enum.with_index()
      |> Enum.map(fn {value, index} -> scatter_fact(fan_out, source_fact, value, index, of) end)

    # A scattered element is just a produced fact (labelled :fan_out) carrying
    # index/of metadata — no bespoke event, no `mapped` bookkeeping.
    fan_out_events =
      Enum.map(emitted_facts, fn fact ->
        %FactProduced{
          hash: fact.hash,
          value: fact.value,
          ancestry: fact.ancestry,
          producer_label: :fan_out,
          meta: fact.meta,
          weight: ctx.ancestry_depth + 1
        }
      end)

    events =
      fan_out_events ++
        [
          %ActivationConsumed{
            fact_hash: source_fact.hash,
            node_hash: fan_out.hash,
            from_label: :runnable
          }
        ]

    Runnable.complete(runnable, emitted_facts, events)
  end
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.FanIn do
  alias Runic.Workflow.FanOut
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    FanIn,
    Runnable,
    CausalContext,
    HookRunner
  }

  alias Runic.Workflow.Events.{FactProduced, ActivationConsumed}

  def match_or_execute(_fan_in), do: :execute

  # Legacy single-pass entry: run the three phases inline so there is exactly one
  # completion path (Coordinator.finalize/3), whether invoked directly or via react.
  def invoke(%FanIn{} = fan_in, %Workflow{} = workflow, %Fact{} = fact) do
    {:ok, runnable} = prepare(fan_in, workflow, fact)
    Workflow.apply_runnable(workflow, execute(fan_in, runnable))
  end

  # Find the source_fact hash that triggered the FanOut
  # This walks up the ancestry chain from the current fact to find the FanOut producer,
  # then returns its parent (the source_fact that was input to the FanOut)
  defp reduce_with_context(enumerable, acc, reducer, effective_context) do
    arity = Function.info(reducer, :arity) |> elem(1)

    if effective_context != %{} and arity == 3 do
      Enum.reduce_while(enumerable, acc, fn value, acc ->
        case reducer.(value, acc, effective_context) do
          {:cont, new_acc} -> {:cont, new_acc}
          {:halt, new_acc} -> {:halt, new_acc}
          new_acc -> {:cont, new_acc}
        end
      end)
    else
      Enum.reduce_while(enumerable, acc, fn value, acc ->
        case reducer.(value, acc) do
          {:cont, new_acc} -> {:cont, new_acc}
          {:halt, new_acc} -> {:halt, new_acc}
          new_acc -> {:cont, new_acc}
        end
      end)
    end
  end

  defp merge_effective_context(meta, run) when map_size(meta) == 0 and map_size(run) == 0, do: %{}
  defp merge_effective_context(meta, run) when map_size(run) == 0, do: meta
  defp merge_effective_context(meta, run) when map_size(meta) == 0, do: run
  defp merge_effective_context(meta, run), do: Map.merge(run, meta)

  def prepare(
        %FanIn{} = fan_in,
        %Workflow{} = workflow,
        %Fact{ancestry: {_parent_step_hash, _}} = fact
      ) do
    fan_out = find_upstream_fan_out(workflow, fan_in)

    meta_context =
      if FanIn.has_meta_refs?(fan_in) do
        Workflow.prepare_meta_context(workflow, fan_in)
      else
        %{}
      end

    run_context = Workflow.get_run_context(workflow, fan_in.name)

    case fan_out do
      nil ->
        # Simple reduce mode - no FanOut upstream
        context =
          CausalContext.new(
            node_hash: fan_in.hash,
            input_fact: fact,
            ancestry_depth: Workflow.ancestry_depth(workflow, fact),
            hooks: Workflow.get_hooks(workflow, fan_in.hash),
            mergeable: fan_in.mergeable,
            fan_in_context: %{mode: :simple},
            meta_context: meta_context,
            run_context: run_context
          )

        {:ok, Runnable.new(fan_in, fact, context)}

      %FanOut{} ->
        # Coordination happens in Coordinator.finalize/3, which recomputes
        # completion structurally from the fact DAG. `prepare` only needs to
        # carry the reduce context (meta/run) for the reducer.
        context =
          CausalContext.new(
            node_hash: fan_in.hash,
            input_fact: fact,
            ancestry_depth: Workflow.ancestry_depth(workflow, fact),
            hooks: Workflow.get_hooks(workflow, fan_in.hash),
            mergeable: fan_in.mergeable,
            fan_in_context: %{mode: :fan_out_reduce},
            meta_context: meta_context,
            run_context: run_context
          )

        {:ok, Runnable.new(fan_in, fact, context)}
    end
  end

  def prepare(%FanIn{} = fan_in, %Workflow{} = _workflow, %Fact{ancestry: nil} = fact) do
    # Root fact - shouldn't happen normally but handle gracefully
    context =
      CausalContext.new(
        node_hash: fan_in.hash,
        input_fact: fact,
        ancestry_depth: 0,
        hooks: {[], []},
        mergeable: fan_in.mergeable,
        fan_in_context: %{mode: :simple},
        meta_context: %{},
        run_context: %{}
      )

    {:ok, Runnable.new(fan_in, fact, context)}
  end

  def execute(
        %FanIn{init: init, reducer: reducer} = fan_in,
        %Runnable{input_fact: fact, context: ctx} = runnable
      ) do
    case ctx.fan_in_context.mode do
      :simple ->
        with {:ok, before_apply_fns} <- HookRunner.run_before(ctx, fan_in, fact) do
          effective_context = merge_effective_context(ctx.meta_context, ctx.run_context)
          reduced = reduce_with_context(fact.value, init.(), reducer, effective_context)
          reduced_fact = Fact.new(value: reduced, ancestry: {fan_in.hash, fact.hash})

          case HookRunner.run_after(ctx, fan_in, fact, reduced_fact) do
            {:ok, after_apply_fns} ->
              events = [
                %FactProduced{
                  hash: reduced_fact.hash,
                  value: reduced_fact.value,
                  ancestry: reduced_fact.ancestry,
                  producer_label: :reduced,
                  weight: ctx.ancestry_depth + 1
                },
                %ActivationConsumed{
                  fact_hash: fact.hash,
                  node_hash: fan_in.hash,
                  from_label: :runnable
                }
              ]

              hook_fns = before_apply_fns ++ after_apply_fns
              Runnable.complete(runnable, reduced_fact, events, hook_fns)

            {:error, reason} ->
              Runnable.fail(runnable, {:hook_error, reason})
          end
        else
          {:error, reason} ->
            Runnable.fail(runnable, {:hook_error, reason})
        end

      :fan_out_reduce ->
        # Coordination node: always just produce ActivationConsumed.
        # Completion check happens in maybe_finalize_coordination/2 during apply,
        # which rechecks mapped state (handles concurrent arrivals correctly).
        events = [
          %ActivationConsumed{
            fact_hash: fact.hash,
            node_hash: fan_in.hash,
            from_label: :runnable
          }
        ]

        Runnable.complete(runnable, :waiting, events)
    end
  end

  defp find_upstream_fan_out(workflow, fan_in) do
    workflow.graph
    |> Multigraph.in_edges(fan_in)
    |> Enum.filter(&(&1.label == :fan_in))
    |> List.first(%{})
    |> Map.get(:v1)
  end
end
