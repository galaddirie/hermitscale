# Workflow Rewriting & Recursive Language Models — Exploration

> **Status**: Exploration  
> **Related**: [LLM & Agents Use Case](./runic-llms-and-agents-use-case-exploration.md), [State-Based Components](./state-based-component-exploration.md), [Future Components](./future-component-exploration.md), [Causal Runtime Architecture](./causal-runtime-architecture.md), [Runtime Context Proposal](./runtime-context-proposal.md)  
> **Goal**: Explore how Runic's typed dynamic workflow construction can serve as the substrate for Recursive Language Model (RLM) agent systems — specifically continuation-style workflows where the graph rewrites itself in pursuit of objectives not determined at construction time.

---

## Table of Contents

1. [Motivation & Framing](#motivation--framing)
2. [Prior Art: RLM Architectures](#prior-art-rlm-architectures)
   - [Standard RLM (REPL + Recursion)](#standard-rlm-repl--recursion)
   - [Lambda-RLM (Typed Functional Control)](#lambda-rlm-typed-functional-control)
   - [Slate (Thread Weaving & Episodes)](#slate-thread-weaving--episodes)
3. [Theoretical Foundations](#theoretical-foundations)
   - [Wolfram Rule Rewriting & Multiway Systems](#wolfram-rule-rewriting--multiway-systems)
   - [Graph Rewriting Systems & Double Pushout](#graph-rewriting-systems--double-pushout)
   - [Fixed Points, Y-Combinators, & Recursive Types](#fixed-points-y-combinators--recursive-types)
   - [Category-Theoretic Perspective: Coalgebras & Unfolds](#category-theoretic-perspective-coalgebras--unfolds)
   - [Cybernetic Feedback & Viable System Model](#cybernetic-feedback--viable-system-model)
4. [Runic's Existing Primitives for Self-Modification](#runics-existing-primitives-for-self-modification)
   - [Hooks as Proto-Continuations](#hooks-as-proto-continuations)
   - [Activator Protocol & Dynamic Downstream](#activator-protocol--dynamic-downstream)
   - [Three-Phase Model as Suspension Points](#three-phase-model-as-suspension-points)
   - [Workflow.add at Runtime](#workflowadd-at-runtime)
5. [Design: Workflow as Rewriting System](#design-workflow-as-rewriting-system)
   - [The Continuation Contract](#the-continuation-contract)
   - [Step Return Types: Value | SubWorkflow | Continuation](#step-return-types-value--subworkflow--continuation)
   - [Typed Workflow Expansion](#typed-workflow-expansion)
   - [Termination & Depth Bounds](#termination--depth-bounds)
6. [Architecture: Runic as RLM Substrate](#architecture-runic-as-rlm-substrate)
   - [Symbolic Context as Facts, Not Tokens](#symbolic-context-as-facts-not-tokens)
   - [The Planner-Expander-Leaf Pattern](#the-planner-expander-leaf-pattern)
   - [Lambda-RLM Operators as Runic Components](#lambda-rlm-operators-as-runic-components)
   - [Coherence via Causal Ancestry](#coherence-via-causal-ancestry)
   - [Dynamic Delegation with Goal Alignment](#dynamic-delegation-with-goal-alignment)
7. [Livebook as REPL Environment](#livebook-as-repl-environment)
8. [API Sketches](#api-sketches)
   - [Continuation Steps](#continuation-steps)
   - [Workflow Expanders](#workflow-expanders)
   - [Goal-Directed React Loop](#goal-directed-react-loop)
   - [RLM Agent Construction](#rlm-agent-construction)
9. [Compositional Patterns](#compositional-patterns)
   - [Recursive Map-Reduce over Context](#recursive-map-reduce-over-context)
   - [Adaptive Fan-Out with Depth Control](#adaptive-fan-out-with-depth-control)
   - [Plan-Extract-Review-Generate Pipeline](#plan-extract-review-generate-pipeline)
   - [Reflexive Goal Decomposition](#reflexive-goal-decomposition)
10. [Comparison with Existing Approaches](#comparison-with-existing-approaches)
11. [Concerns & Trade-offs](#concerns--trade-offs)
12. [Open Questions](#open-questions)
13. [References](#references)

---

## Motivation & Framing

### The Core Insight

Current RLM/agent architectures face a fundamental tension: **the model must decompose tasks it hasn't fully understood yet, using a decomposition strategy it invents at runtime.** Open-ended REPL-based approaches (standard RLM) let the model do this freely but suffer from context rot, token waste, and unpredictable compute. Rigid pipeline approaches (Lambda-RLM) fix the decomposition but lose adaptability.

Runic occupies a unique position in this design space. As a **typed, dynamically composable workflow graph with causal tracking**, it can express something neither pure REPL freedom nor pure pipeline rigidity achieves: **a workflow that rewrites itself according to typed rules, where each rewrite is a first-class graph operation with causal ancestry, and termination is guaranteed by structural constraints rather than arbitrary depth limits.**

This is not "a model with a REPL." It is a **workflow rewriting system** — a computational substrate where:

1. **The workflow graph is the plan** (Lambda-RLM's insight)
2. **The graph can grow during execution** (RLM's flexibility)
3. **Growth follows typed expansion rules** (Lambda-RLM's guarantees)
4. **Every expansion is causally tracked** (Runic's unique contribution)
5. **Coherence is structural, not contextual** (avoiding context rot)

### The Organizational Metaphor

The problem of coordinating LLM agents mirrors the problem of coordinating humans in organizations. A principal delegates to agents who may themselves delegate. Information compresses at each boundary. Goals drift. The deeper the delegation chain, the more likely the leaf worker is misaligned with the original objective.

Stafford Beer's Viable System Model (VSM) addresses this with recursive self-similar structure: each organizational unit contains a complete management structure, and units communicate through specific channels (coordination, monitoring, adaptation). Runic's workflow graph, with its causal ancestry and typed composition, can serve as exactly this kind of recursive self-similar coordination structure — where the "management" at each level is the workflow's own typing and causal tracking, not a heavyweight planning agent.

---

## Prior Art: RLM Architectures

### Standard RLM (REPL + Recursion)

From [Zhang & Khattab (2024)](https://arxiv.org/abs/2512.24601) and the [Prime Intellect replication](https://www.primeintellect.ai/blog/rlm):

**Architecture**: Model receives a persistent Python REPL. Context lives as variables in the REPL, not tokens in the window. The model writes code to interact with context — slicing, filtering, dispatching sub-LLM calls, accumulating results.

**Three conditions** separating an RLM from "a model with a REPL":
1. **Symbolic input** — context is a variable, not tokens
2. **Persistent execution** — REPL state persists across turns
3. **Recursive LLM invocation** — code can invoke LLMs inside loops

**Strengths**: O(n) or O(n²) semantic work over length-n input. Decomposition emerges naturally. Maximum flexibility.

**Weaknesses**: Unpredictable compute (2.1× token variance on identical inputs per [The Harness](https://theharness.blog/blog/recursive-by-design/)). Context rot as the REPL session grows. No formal termination guarantees. No structured way to maintain goal coherence across recursive calls.

**Runic Mapping**: The REPL's persistent state ↔ Runic's fact graph. Recursive LLM invocation ↔ dynamic workflow expansion. But Runic adds what the REPL lacks: **typed structure, causal tracking, and composition guarantees.**

### Lambda-RLM (Typed Functional Control)

From [Lambda-RLM (2025)](https://arxiv.org/abs/2603.20105) and [The Harness blog](https://theharness.blog/blog/recursive-by-design/):

**Key Insight**: "The task structure already contains the plan." Replace open-ended REPL loops with a deterministic pipeline. Confine the model to bounded leaf operations. Handle decomposition with pure code.

**Architecture**: Four phases — Plan (zero LLM calls, compute decomposition), Extract (bounded leaf operations), Review (contract alignment check), Generate (compose from extractions).

**Operators**: `SPLIT`, `MAP`, `FILTER`, `REDUCE`, `CONCAT`, `CROSS` — a typed functional runtime grounded in λ-calculus.

**Results**: 14× fewer tokens, +8.4% quality, exact cost prediction before first API call. 29/36 wins over standard RLM.

**Runic Mapping**: Lambda-RLM's operators map directly to Runic components:

| λ-RLM Operator | Runic Component |
|---|---|
| `SPLIT` | `FanOut` |
| `MAP` | `Runic.map/2` (FanOut + Step + FanIn) |
| `FILTER` | `Rule` with condition |
| `REDUCE` | `Runic.reduce/2` (FanOut + Step + Accumulator + FanIn) |
| `CONCAT` | Step (list concatenation) |
| `CROSS` | Nested `map` with `Join` |
| Leaf LLM call | Step with `run_context` for API keys |
| Plan phase | Workflow construction (zero LLM calls) |
| Review phase | Rule with `state_of()` checking extraction quality |

**The difference**: Lambda-RLM's pipeline is fixed at plan time. Runic can express the same typed structure **and** allow it to grow during execution — typed expansion rather than unconstrained REPL mutation.

### Slate (Thread Weaving & Episodes)

From [Random Labs (2025)](https://randomlabs.ai/blog/slate):

**Key Insight**: Single-threaded agents haven't been solved. Don't force multi-agent architectures yet. Instead, use episodic context management within a single orchestration thread.

**Architecture**: A central orchestrator delegates to worker threads via a DSL. Workers execute, compress their context into "episodes," and return. The orchestrator sees compressed summaries. Key property: episodes provide isolation + compaction without losing coherence.

**Comparison to RLM**: RLM gives the model massive flexibility but no synchronization. Slate gives synchronization (episodes are the sync boundary) while maintaining expressivity (the orchestrator uses a highly expressive DSL, not rigid task trees).

**Runic Mapping**: Slate's "episodes" ↔ Runic's sub-workflows executed via `react_until_satisfied` and compressed back to a fact. The orchestrator ↔ the parent workflow. The DSL ↔ Runic's component constructors. But Runic provides something Slate lacks: **the episode's internal structure is a typed, inspectable graph**, not an opaque thread.

---

## Theoretical Foundations

### Wolfram Rule Rewriting & Multiway Systems

Stephen Wolfram's computational physics models use **rule rewriting on hypergraphs**:

- A system state is a set of relations (hyperedges between elements)
- Rules match sub-patterns and replace them with new patterns
- Application is non-deterministic — multiple rules may match simultaneously
- The **multiway system** explores all possible rule applications, producing a causal graph of states

Runic workflows are already a labeled multigraph with causal tracking. The connection to Wolfram rewriting is direct:

| Wolfram Concept | Runic Analog |
|---|---|
| Hypergraph state | Workflow graph (vertices = components + facts, edges = causal links) |
| Rewriting rule | Hook `{:apply, fn workflow -> modified_workflow end}` or continuation step |
| Rule application | `apply_runnable/2` in the apply phase |
| Causal edge | `%Fact{ancestry: {producer_hash, parent_fact_hash}}` |
| Multiway branch | Parallel runnables producing different graph modifications |
| Causal invariant | Content-addressed hashing — same inputs ⇒ same fact hash |

The critical property Wolfram identifies is **causal invariance**: regardless of the order rules are applied, the same causal relationships emerge. Runic's content-addressed fact hashing provides exactly this — the graph converges to the same causal structure regardless of execution order, because `ancestry = {producer_hash, input_fact_hash}` is deterministic.

A workflow rewriting itself during execution is a **multiway graph rewriting system with typed rules**. Each "rewrite" (hook apply_fn adding new components) is a local graph transformation. The causal ancestry ensures we can always trace why a particular subgraph exists.

### Graph Rewriting Systems & Double Pushout

In the algebraic graph rewriting tradition (Ehrig, Rozenberg), graph transformations are formalized via **double-pushout (DPO)** rules:

```
    L ←── K ──→ R
    ↓     ↓     ↓
    G ←── D ──→ H
```

- **L** (left-hand side): pattern to match in graph G
- **K** (kernel/interface): preserved structure
- **R** (right-hand side): replacement pattern
- **G → D**: remove matched elements not in K
- **D → H**: add new elements from R

In Runic's continuation model:

- **L**: the current workflow state + the activating fact (the pattern we're matching)
- **K**: the existing workflow graph minus any removed components
- **R**: the expanded workflow with new components/edges
- **G → D**: `Workflow.remove_component/2` (optional — remove completed subgraphs)
- **D → H**: `Workflow.add/3` (adding new steps, rules, sub-workflows)

The `{:apply, fn workflow -> ... end}` hook return is literally a graph rewrite rule: it takes the current graph G and produces a new graph H, preserving the interface K.

### Fixed Points, Y-Combinators, & Recursive Types

Lambda-RLM explicitly invokes the Y-combinator analogy. In λ-calculus, the Y-combinator enables recursion without self-reference:

```
Y = λf. (λx. f(x x))(λx. f(x x))
```

The key property: Y transforms a non-recursive function into its recursive fixed point. The function doesn't "know" it's recursive — the combinator handles the self-application.

Runic's continuation model provides the same structural recursion:

```elixir
# A step doesn't "know" it can expand the workflow.
# The workflow engine handles the self-application.

step = Runic.step(fn input, ctx ->
  case analyze(input) do
    {:leaf, value} -> 
      value  # base case — produce a direct result

    {:branch, sub_problems} -> 
      # recursive case — return a sub-workflow
      {:continue, build_sub_workflow(sub_problems)}
  end
end, name: :solver)
```

The step is a non-recursive function. The workflow engine's continuation handling is the Y-combinator — it takes the step's `{:continue, sub_workflow}` return and applies it back into the graph. The recursion is in the **structure**, not in the function.

**Recursive types**: In type theory, a recursive type μX.F(X) is the fixed point of a type constructor F. A Runic workflow that can expand itself is a recursive type:

```
Workflow = μW. Graph(Component, W)
```

A workflow is a graph of components, where some components may produce new workflows. The fixed point is reached when all components produce values rather than sub-workflows — the **satisfaction** condition.

### Category-Theoretic Perspective: Coalgebras & Unfolds

A workflow that grows during execution is an **unfold** (anamorphism) — the categorical dual of a fold (catamorphism):

- **Fold** (catamorphism): collapse structure into a value. Runic's `Accumulator` and `Reduce` are folds.
- **Unfold** (anamorphism): grow structure from a seed. A continuation step is an unfold — from a seed (the input fact), it produces new structure (sub-workflow) and new seeds (facts flowing into the sub-workflow).

The combined fold-unfold is a **hylomorphism**: unfold to build a structure, then fold to collapse it. This is exactly the Lambda-RLM pattern:

1. **Plan** (unfold): from a task description, construct a decomposition tree
2. **Extract** (leaves): bounded LLM calls at the leaves
3. **Generate** (fold): compose results back up the tree

In Runic terms:

1. **Continuation steps** unfold the workflow graph (anamorphism)
2. **Leaf steps** produce facts (base case)
3. **Accumulators / Reduce** fold facts back into results (catamorphism)

The hylomorphism decomposes into an unfold followed by a fold. Runic's `react_until_satisfied` naturally implements this: it keeps expanding (unfolding) while there are continuations to resolve, and simultaneously folding results through accumulators, until the graph reaches a fixed point (satisfaction).

### Cybernetic Feedback & Viable System Model

Stafford Beer's Viable System Model (VSM) describes recursive organizational structure:

```
System 5: Identity (purpose, values)
System 4: Adaptation (environment scanning, future planning)  
System 3: Control (resource allocation, optimization)
System 2: Coordination (conflict resolution, scheduling)
System 1: Operations (value-creating units, each itself a viable system)
```

Each System 1 unit is itself a viable system with its own S1-S5. The recursion is self-similar.

Mapping to an RLM agent built on Runic:

| VSM System | Runic Analog |
|---|---|
| S5 Identity | The root workflow's `name` and terminal condition — "what are we trying to produce?" |
| S4 Adaptation | Review steps that check extraction quality against requirements (Lambda-RLM's Review phase) |
| S3 Control | `SchedulerPolicy` — resource allocation, concurrency limits, timeout management |
| S2 Coordination | `Join`, `FanIn`, causal ancestry — ensuring sub-results align before composition |
| S1 Operations | Leaf steps / sub-workflows — the actual LLM calls and computations |

The critical VSM insight for RLM design: **each delegation must carry enough of S5 (identity/purpose) to keep the delegate aligned.** In Runic, this is the causal ancestry chain + run_context. A sub-workflow knows its purpose because:

1. Its triggering fact carries the goal (causal ancestry traces back to the original objective)
2. Its run_context carries the constraints (model, tokens budget, quality threshold)
3. Its terminal condition defines what "done" means for this sub-problem

This is how Runic avoids the goal-drift problem that plagues deep delegation chains.

---

## Runic's Existing Primitives for Self-Modification

### Hooks as Proto-Continuations

The hook system already supports workflow self-modification. An arity-2 hook can return `{:apply, fn workflow -> modified_workflow end}`, which is executed during the apply phase:

```elixir
# From HookRunner — this IS a continuation
fn %HookEvent{result: fact}, _ctx ->
  case fact.value do
    {:needs_more_work, sub_tasks} ->
      {:apply, fn workflow ->
        sub_workflow = build_sub_workflow(sub_tasks)
        Workflow.merge(workflow, sub_workflow)
      end}

    {:done, result} ->
      :ok  # no modification needed
  end
end
```

This is the proto-continuation contract: "maybe return a result, or return more workflow to execute." The hook inspects execution results and decides whether the graph needs expansion.

**Limitation**: Hooks are attached to specific nodes. They can't easily express "if any node in this sub-graph produces an unsatisfying result, expand." This requires a more general continuation mechanism.

### Activator Protocol & Dynamic Downstream

The `Activator` protocol determines what downstream nodes become runnable after a node completes. Currently, activators look up pre-existing edges. But the protocol is open — a custom activator could **create** new downstream nodes:

```elixir
defimpl Runic.Workflow.Activator, for: MyApp.ContinuationStep do
  def activate_downstream(%MyApp.ContinuationStep{}, workflow, runnable) do
    case runnable.result do
      %Fact{value: {:continue, sub_wf}} ->
        # Merge sub-workflow into current workflow, wire edges
        {workflow, events} = expand_and_wire(workflow, sub_wf, runnable)
        {workflow, events}

      %Fact{} ->
        # Normal result — activate pre-existing downstream
        default_activate(workflow, runnable)
    end
  end
end
```

This is a natural extension point — the Activator protocol already sits at exactly the right place in the execution lifecycle (post-execute, pre-next-cycle).

### Three-Phase Model as Suspension Points

The prepare → execute → apply model already provides natural suspension points:

1. **After prepare**: The runnable is a self-contained unit. It can be serialized, stored, sent to a remote executor, or held for human review.
2. **After execute**: The result is computed but not yet applied. This is where we decide: is this a terminal result, or does it spawn more work?
3. **After apply**: The graph has been updated. New runnables may have been created by the expansion. The cycle continues.

A continuation-based workflow uses these suspension points as **decision points** for whether to expand the graph or accept the result.

### Workflow.add at Runtime

`Workflow.add/3` already supports adding components to a running workflow. Combined with `Workflow.plan_eagerly/2`, newly added components are immediately considered for activation. This means graph expansion during execution is a first-class operation — no special machinery needed for the "add new steps" part. What's missing is the **typed contract** for when and how to expand.

---

## Design: Workflow as Rewriting System

### The Continuation Contract

The core abstraction is a **continuation**: a step that may produce a direct result OR a sub-workflow that, when executed to satisfaction, produces the result the step was supposed to.

```elixir
@type continuation_result ::
  {:value, term()}              # terminal — direct result
  | {:continue, Workflow.t()}   # expansion — sub-workflow to execute
  | {:continue, Workflow.t(), continuation_opts()}  # expansion with constraints
  | {:delegate, [delegation()]} # multi-way expansion — parallel sub-workflows
```

**Continuation options** carry the VSM "identity" forward:

```elixir
@type continuation_opts :: %{
  optional(:max_depth) => non_neg_integer(),     # termination guarantee
  optional(:token_budget) => non_neg_integer(),  # resource bound
  optional(:quality_threshold) => float(),       # acceptance criterion
  optional(:timeout_ms) => non_neg_integer(),    # wall-clock bound
  optional(:goal) => term()                      # the objective to satisfy
}
```

### Step Return Types: Value | SubWorkflow | Continuation

A continuation step is an ordinary step whose work function returns one of the continuation types:

```elixir
# A step that might need to recursively decompose
planner = Runic.step(fn input, ctx ->
  case plan_decomposition(input, ctx) do
    {:leaf, problem} ->
      # Small enough to solve directly
      {:value, solve_directly(problem, ctx)}

    {:tree, sub_problems} ->
      # Too complex — build a sub-workflow
      sub_wf = sub_problems
        |> Enum.map(fn sp -> Runic.step(fn _ -> solve(sp) end, name: sp.id) end)
        |> build_map_reduce_workflow()

      {:continue, sub_wf, max_depth: ctx.remaining_depth - 1}
  end
end, name: :planner)
```

The workflow engine recognizes `{:continue, ...}` returns and, instead of wrapping the value in a fact, **merges the sub-workflow into the current graph** at the continuation point.

### Typed Workflow Expansion

Expansion is not arbitrary graph mutation. It follows a typed contract:

1. **The sub-workflow's inputs** are wired to the continuation step's input fact
2. **The sub-workflow's outputs** (terminal facts) are wired to the continuation step's original downstream
3. **The continuation step itself** is replaced by the sub-workflow (or marked as "expanded")
4. **Causal ancestry** is preserved: sub-workflow facts trace back through the continuation step to the original input

This is the **double-pushout rewrite** in action:
- **L** = the continuation step node + its edges
- **K** = the input fact + downstream edges (preserved interface)
- **R** = the sub-workflow graph
- The rewrite replaces L with R while preserving K's connectivity

```
Before expansion:
    [input_fact] → [continuation_step] → [downstream_step]

After expansion:
    [input_fact] → [sub_step_1] → [sub_accumulator] → [downstream_step]
                 → [sub_step_2] ↗
                 → [sub_step_3] ↗
```

### Termination & Depth Bounds

Unbounded self-expansion is the RLM failure mode Slate identifies: "overdecomposition." We need structural termination guarantees.

**Approach 1: Depth counters on CausalContext** (analogous to Lambda-RLM's bounded depth)

```elixir
# The continuation depth is tracked on CausalContext and decremented on each expansion
defstruct [
  # ... existing fields ...
  continuation_depth: 0,
  max_continuation_depth: 10
]
```

When `continuation_depth >= max_continuation_depth`, the engine refuses `{:continue, ...}` returns and forces the step to produce a `{:value, ...}` (or produces a best-effort result via a fallback).

**Approach 2: Token/compute budgets** (resource-bounded, like Lambda-RLM's cost prediction)

```elixir
# Before expanding, check remaining budget
remaining_budget = ctx.token_budget - tokens_consumed_so_far(workflow)
if remaining_budget < estimated_cost(sub_workflow) do
  {:value, best_effort_result(input)}
else
  {:continue, sub_workflow, token_budget: remaining_budget}
end
```

**Approach 3: Structural termination** (the Lambda-RLM insight)

If the decomposition is deterministic (computed from the task structure, not by the model), termination is guaranteed by the structure itself. The model only fills leaves. The expansion tree has a fixed shape computed before any LLM call.

Runic can support all three simultaneously — they compose. Depth bounds are a safety net. Budget bounds are a resource constraint. Structural bounds are the ideal case.

---

## Architecture: Runic as RLM Substrate

### Symbolic Context as Facts, Not Tokens

The first RLM condition — "symbolic input, not tokens" — maps naturally to Runic:

```elixir
# Context is a fact in the workflow, not tokens in the LLM's window
context_fact = Fact.new(value: %{
  documents: documents,           # the actual data — may be megabytes
  goal: "summarize key findings",
  constraints: %{max_length: 2000}
})

# The LLM step receives a REFERENCE to context, not the context itself
llm_step = Runic.step(fn _input, ctx ->
  # ctx.documents is a reference — the step decides how much to read
  relevant = filter_relevant(ctx.documents, ctx.goal)
  call_llm(relevant, ctx.goal)
end, name: :llm_call)
```

Runic's fact graph serves as the persistent symbolic environment. Facts are content-addressed and immutable. The LLM step receives a compact reference (via `run_context` or `meta_context`) and writes code-like logic to interact with the data — exactly the RLM pattern, but with typed composition instead of arbitrary REPL code.

### The Planner-Expander-Leaf Pattern

This is the core pattern for Runic-based RLM agents:

```
                    ┌──────────┐
                    │  Planner │  (zero or one LLM call)
                    │  Step    │  Analyzes input, produces decomposition plan
                    └────┬─────┘
                         │
                    ┌────▼─────┐
                    │ Expander │  (zero LLM calls)
                    │ Hook     │  Reads plan, constructs typed sub-workflow
                    └────┬─────┘
                         │
              ┌──────────┼──────────┐
              │          │          │
         ┌────▼───┐ ┌───▼────┐ ┌──▼────┐
         │ Leaf 1 │ │ Leaf 2 │ │Leaf 3 │  (bounded LLM calls)
         │ (Step) │ │ (Step) │ │(Step) │  Each operates on a chunk
         └────┬───┘ └───┬────┘ └──┬────┘
              │         │         │
              └─────────▼─────────┘
                   ┌────────┐
                   │ Reduce │  (zero LLM calls or one synthesis call)
                   │ /Join  │  Compose sub-results
                   └────────┘
```

**Planner**: Examines the input (document sizes, task structure, dependency graph). Produces a decomposition plan as a pure data structure — no LLM call needed if the task structure is known. One LLM call if the plan requires semantic understanding.

**Expander**: A hook or continuation that reads the plan and constructs a typed Runic sub-workflow. This is pure Elixir code — `Runic.map/2`, `Runic.reduce/2`, `Runic.step/2` composition. The sub-workflow's structure IS the plan.

**Leaves**: Bounded steps that make individual LLM calls. Each receives a chunk of context small enough to fit in one call. Each produces a structured extraction or answer.

**Reduce/Join**: Composes leaf results. May itself be a leaf (one synthesis LLM call) or a pure function (concatenation, merging).

**The recursive case**: If a leaf discovers its chunk is still too large, it becomes a new Planner — producing a sub-plan, triggering a new Expander, creating new Leaves. This is the workflow rewriting itself. The recursion is bounded by depth limits, token budgets, or structural analysis.

### Lambda-RLM Operators as Runic Components

Lambda-RLM's typed functional runtime maps directly onto Runic's existing component library:

```elixir
# SPLIT: FanOut decomposes an enumerable into individual facts
split = Runic.map(fn document ->
  chunk_document(document, chunk_size: 4000)
end)

# MAP: Apply a function to each element (FanOut + Step + FanIn)
extract = Runic.map(fn chunk, ctx ->
  call_llm("Extract key facts from: #{chunk}", ctx.model)
end)

# FILTER: Rule with condition — keeps facts matching a predicate
relevant = Runic.rule(
  name: :filter_relevant,
  condition: fn extraction -> extraction.confidence > 0.7 end,
  reaction: fn extraction -> extraction end
)

# REDUCE: Fold extracted facts into a single result
synthesize = Runic.reduce(
  fn extraction, acc ->
    Map.merge(acc, extraction, fn _k, v1, v2 -> v1 ++ v2 end)
  end,
  %{}
)

# CROSS: Nested map — for each (section, source) pair
cross_product = fn sections, sources ->
  Runic.map(fn section ->
    Runic.map(fn source ->
      extract_for_section(source, section)
    end).(sources)
  end).(sections)
end
```

The difference from Lambda-RLM's Python implementation: **these are first-class graph components with causal tracking, parallel dispatch, and typed composition.** The workflow engine handles scheduling, retries, and resource management — the LLM steps are just leaf functions.

### Coherence via Causal Ancestry

The goal-drift problem in multi-level delegation chains: by the time you're three levels deep, the leaf agent may have lost sight of the original objective.

Runic's causal ancestry addresses this structurally:

```elixir
# Every fact traces back to its root input through causal ancestry
%Fact{
  value: extracted_data,
  ancestry: {
    :leaf_extractor_hash,    # who produced this
    %Fact{                    # from what input
      ancestry: {
        :expander_hash,       # who produced the chunk
        %Fact{                
          ancestry: {
            :planner_hash,    # who decomposed the task
            original_goal_fact  # THE ORIGINAL OBJECTIVE
          }
        }
      }
    }
  }
}
```

At any depth, we can traverse the ancestry chain to recover the original goal. A review step can check: "does this leaf result serve the original objective?" by comparing `root_ancestor(fact)` against the acceptance criterion.

Furthermore, the `run_context` mechanism carries forward constraints and identity at every level:

```elixir
Workflow.react_until_satisfied(workflow, input,
  run_context: %{
    _global: %{
      original_goal: "Summarize environmental impact findings",
      quality_threshold: 0.8,
      remaining_depth: 3,
      model: "anthropic:claude-sonnet-4-20250514"
    },
    leaf_extractor: %{api_key: resolved_key}
  }
)
```

### Dynamic Delegation with Goal Alignment

Combining continuation steps with goal-carrying run_context:

```elixir
# A goal-aware continuation step
Runic.step(fn input, ctx ->
  goal = ctx.original_goal
  depth = ctx.remaining_depth

  # Ask an LLM: "Can you solve this in one shot, or should we decompose?"
  assessment = assess_complexity(input, goal, ctx.model)

  case assessment do
    %{solvable_directly: true} ->
      {:value, solve(input, goal, ctx)}

    %{sub_goals: sub_goals} when depth > 0 ->
      # Build a typed sub-workflow for each sub-goal
      sub_workflow = sub_goals
        |> Enum.map(&build_goal_workflow(&1, depth - 1))
        |> compose_with_join(goal)

      {:continue, sub_workflow}

    %{sub_goals: _} when depth <= 0 ->
      # Depth limit reached — best effort
      {:value, best_effort_solve(input, goal, ctx)}
  end
end, name: :goal_solver)
```

---

## Livebook as REPL Environment

Several practitioners have reported success using Livebook notebooks as the REPL environment for RLM-style agents. This is a natural fit for Runic:

1. **Livebook cells as workflow construction sites**: An agent constructs Runic workflows in Livebook cells, executes them, inspects results in subsequent cells.

2. **Kino integration**: Runic already has `Runic.Kino` for workflow visualization. An RLM agent could use Kino to render its current plan (workflow graph) for human inspection between steps.

3. **Persistent state**: Livebook's cell evaluation model provides the "persistent REPL" that RLMs require. Variables (including workflow structs) persist across cells.

4. **Human-in-the-loop**: Livebook's interactive nature allows human review of intermediate results — the "Approval Gate" pattern from the future components exploration, implemented naturally.

```elixir
# Cell 1: Agent constructs a workflow
require Runic
workflow = build_analysis_workflow(documents, goal)
Runic.Kino.render(workflow)

# Cell 2: Agent executes and inspects
workflow = Workflow.react_until_satisfied(workflow, input)
results = Workflow.results(workflow)
# Agent reviews results, decides if more work is needed

# Cell 3: Agent expands the workflow based on results
if needs_deeper_analysis?(results) do
  sub_workflow = build_deeper_analysis(results.gaps)
  workflow = Workflow.merge(workflow, sub_workflow)
  workflow = Workflow.react_until_satisfied(workflow, results)
end
```

This is the RLM pattern — symbolic context (workflow + facts), persistent execution (Livebook cells), recursive invocation (workflow expansion) — implemented with typed, inspectable graph primitives instead of arbitrary Python code.

---

## API Sketches

### Continuation Steps

```elixir
# Option A: Return-type based continuation (simplest)
step = Runic.step(fn input, ctx ->
  case decompose(input) do
    {:leaf, value} -> value                    # normal fact production
    {:sub, sub_wf} -> {:continue, sub_wf}      # workflow expansion
  end
end, name: :adaptive_solver, continuation: true)

# Option B: Explicit continuation component
solver = Runic.continuation(
  name: :adaptive_solver,
  work: fn input, ctx -> decompose_and_solve(input, ctx) end,
  max_depth: 5,
  on_depth_exceeded: fn input, ctx -> best_effort(input, ctx) end
)

# Option C: Expansion hook (most aligned with existing primitives)
step = Runic.step(fn input -> solve_or_decompose(input) end, name: :solver)

expansion_hook = fn %HookEvent{result: fact}, ctx ->
  case fact.value do
    {:continue, sub_problems} ->
      {:apply, fn workflow ->
        sub_wf = build_sub_workflow(sub_problems)
        merge_as_continuation(workflow, :solver, sub_wf)
      end}

    _ -> :ok
  end
end

workflow = workflow
  |> Workflow.attach_after_hook(:solver, expansion_hook)
```

### Workflow Expanders

A first-class component that expands the workflow based on a planning function:

```elixir
# An expander takes an input and produces new workflow structure
expander = Runic.expander(
  name: :task_decomposer,
  plan: fn input, ctx ->
    # Returns a workflow fragment to merge into the parent
    tasks = decompose_task(input, ctx.goal)

    tasks
    |> Enum.map(fn task ->
      Runic.step(fn _ -> execute_task(task, ctx) end, name: task.id)
    end)
    |> Runic.parallel()
    |> Runic.then(Runic.reduce(fn result, acc -> merge_results(result, acc) end, %{}))
  end,
  max_expansions: 10,
  depth_budget: 3
)
```

### Goal-Directed React Loop

Extend `react_until_satisfied` with goal-directed termination and continuation handling:

```elixir
# react_until_satisfied already checks `is_satisfied?/1` — extend with goal checking
Workflow.react_until_goal(workflow, input,
  goal: fn workflow ->
    results = Workflow.results(workflow)
    quality_score(results) >= 0.8
  end,
  max_depth: 5,
  on_continuation: fn workflow, continuation_fact ->
    # Called when a step returns {:continue, sub_wf}
    # Merge sub_wf, wire edges, continue
    expand_continuation(workflow, continuation_fact)
  end,
  on_depth_exceeded: fn workflow ->
    # Forced termination — collect best partial results
    Workflow.force_satisfy(workflow)
  end
)
```

### RLM Agent Construction

Putting it together — a complete RLM agent built on Runic:

```elixir
defmodule MyApp.RLMAgent do
  require Runic
  alias Runic.Workflow

  def build_agent(goal, documents, opts \\ []) do
    model = opts[:model] || "anthropic:claude-sonnet-4-20250514"
    max_depth = opts[:max_depth] || 5

    # Phase 1: Plan — analyze documents, compute decomposition
    planner = Runic.step(fn input, ctx ->
      docs = input.documents
      goal = input.goal

      # Measure documents, compute optimal chunking
      plan = compute_plan(docs, goal, ctx.context_window)

      %{plan: plan, goal: goal, documents: docs}
    end, name: :planner)

    # Phase 2: Extract — map over chunks with bounded LLM calls
    extractor = Runic.map(fn chunk, ctx ->
      call_llm(
        "Extract information relevant to: #{ctx.goal}\n\nFrom:\n#{chunk}",
        ctx
      )
    end, name: :extract)

    # Phase 3: Review — check extraction quality
    reviewer = Runic.step(fn extractions, ctx ->
      gaps = find_gaps(extractions, ctx.goal)

      case gaps do
        [] -> {:complete, extractions}
        gaps when ctx.remaining_depth > 0 ->
          {:continue, build_re_extraction_workflow(gaps, ctx)}
        _ -> {:best_effort, extractions}
      end
    end, name: :review)

    # Phase 4: Generate — compose final result
    generator = Runic.step(fn extractions, ctx ->
      call_llm(
        "Synthesize these extractions into a coherent response for: #{ctx.goal}\n\n#{format(extractions)}",
        ctx
      )
    end, name: :generate)

    # Compose into workflow
    workflow = Runic.workflow(
      name: :rlm_agent,
      steps: [
        {planner, [{extractor, [{reviewer, [generator]}]}]}
      ]
    )

    # Attach continuation hook to reviewer
    workflow = Workflow.attach_after_hook(workflow, :review, fn event, _ctx ->
      case event.result.value do
        {:continue, sub_wf} ->
          {:apply, fn wf -> merge_as_continuation(wf, :review, sub_wf) end}
        _ -> :ok
      end
    end)

    {workflow, %{
      documents: documents,
      goal: goal,
      model: model,
      remaining_depth: max_depth,
      context_window: 100_000
    }}
  end

  def run({workflow, context}) do
    Workflow.react_until_satisfied(workflow, context,
      run_context: %{
        _global: context,
        extract: %{api_key: System.fetch_env!("LLM_API_KEY")},
        generate: %{api_key: System.fetch_env!("LLM_API_KEY")}
      }
    )
  end
end
```

---

## Compositional Patterns

### Recursive Map-Reduce over Context

The most common RLM pattern: split a large context, map an LLM operation over chunks, reduce results. If a chunk is still too large, recurse.

```elixir
defp build_recursive_map_reduce(process_fn, reduce_fn, opts) do
  max_chunk = opts[:max_chunk_size] || 4000
  depth = opts[:depth] || 0
  max_depth = opts[:max_depth] || 5

  Runic.step(fn input, ctx ->
    if String.length(input) <= max_chunk do
      # Base case — process directly
      process_fn.(input, ctx)
    else
      # Recursive case — split, process each chunk, reduce
      chunks = chunk_text(input, max_chunk)

      if depth < max_depth do
        sub_wf = chunks
          |> Enum.map(fn chunk ->
            build_recursive_map_reduce(process_fn, reduce_fn,
              Keyword.merge(opts, depth: depth + 1))
          end)
          |> compose_parallel_with_reduce(reduce_fn)

        {:continue, sub_wf}
      else
        # Depth limit — truncate and process
        process_fn.(String.slice(input, 0, max_chunk), ctx)
      end
    end
  end, name: :"map_reduce_d#{depth}")
end
```

### Adaptive Fan-Out with Depth Control

Fan-out where the branching factor is determined at runtime by analyzing the input:

```elixir
# The fan-out step decides how many branches based on input analysis
adaptive_split = Runic.step(fn input, ctx ->
  analysis = analyze_structure(input)

  branches = analysis.natural_sections
    |> Enum.map(fn section ->
      %{section: section, estimated_tokens: estimate_tokens(section)}
    end)

  # Compute optimal branching factor (Lambda-RLM's k* formula)
  k_star = compute_optimal_branching(
    branches,
    ctx.context_window,
    ctx.accuracy_target
  )

  # Group sections into k_star chunks
  groups = Enum.chunk_every(branches, ceil(length(branches) / k_star))

  {:delegate, Enum.map(groups, &build_group_workflow/1)}
end, name: :adaptive_fanout)
```

### Plan-Extract-Review-Generate Pipeline

The full Lambda-RLM pipeline as a Runic workflow:

```elixir
def build_lambda_rlm_pipeline(template, sources) do
  # Plan: compute decomposition from template structure (0 LLM calls)
  plan = compute_plan(template, sources)
  estimated_cost = estimate_cost(plan)
  
  IO.puts("Estimated cost: #{estimated_cost} tokens, #{plan.total_calls} calls")

  # Build the workflow from the plan
  section_workflows = plan.sections
    |> Enum.map(fn section ->
      # Extract: bounded leaf LLM calls
      extractors = section.source_chunks
        |> Enum.map(fn chunk ->
          Runic.step(fn _input, ctx ->
            extract(chunk, section.requirements, ctx)
          end, name: :"extract_#{section.name}_#{chunk.id}")
        end)

      # Review: contract alignment check (1 call per section)
      reviewer = Runic.step(fn extractions, ctx ->
        review_contract(extractions, section.requirements, ctx)
      end, name: :"review_#{section.name}")

      # Generate: compose from extractions (1 call per section)
      generator = Runic.step(fn reviewed, ctx ->
        generate_section(reviewed, section.template, ctx)
      end, name: :"generate_#{section.name}")

      {extractors, reviewer, generator}
    end)

  # Compose respecting dependency order from template
  compose_with_dependencies(section_workflows, template.dependency_tree)
end
```

### Reflexive Goal Decomposition

A pattern where the workflow examines its own results and decides whether to expand:

```elixir
# An accumulator tracks goal progress
goal_tracker = Runic.accumulator(
  %{satisfied: [], unsatisfied: [], attempts: 0},
  fn result, state ->
    case assess_against_goal(result, state) do
      :satisfied -> 
        %{state | satisfied: [result | state.satisfied]}
      {:unsatisfied, reason} -> 
        %{state | unsatisfied: [{result, reason} | state.unsatisfied],
                  attempts: state.attempts + 1}
    end
  end,
  name: :goal_tracker
)

# A rule watches goal_tracker state and triggers re-expansion
re_expand_rule = Runic.rule(
  name: :re_expand_if_needed,
  condition: fn _ ->
    state = state_of(:goal_tracker)
    length(state.unsatisfied) > 0 and state.attempts < 3
  end,
  reaction: fn _ ->
    state = state_of(:goal_tracker)
    {:re_extract, state.unsatisfied}
  end
)
```

---

## Comparison with Existing Approaches

| Property | Standard RLM | Lambda-RLM | Slate | **Runic RLM** |
|---|---|---|---|---|
| **Decomposition** | Model decides (REPL) | Structure decides (plan) | Model decides (DSL) | Structure decides, model fills leaves, graph can self-expand |
| **Synchronization** | REPL return | Deterministic pipeline | Episode compress | Causal ancestry + typed graph edges |
| **Context isolation** | Per subcall | Per leaf | Per thread/episode | Per sub-workflow, with typed `run_context` |
| **Context compaction** | REPL slicing | Structural (only leaves) | Episode compress | Fact graph (only terminal facts propagate) |
| **Parallel execution** | In REPL (threads) | Embarrassingly parallel leaves | Native threads | `Task.async_stream` + `SchedulerPolicy` |
| **Termination guarantee** | Depth limit (fragile) | Structural (strong) | Episode limit | Structural + depth + budget (composable) |
| **Goal coherence** | Degrades with depth | Fixed by template | Episode summaries | Causal ancestry traces to root goal |
| **Cost predictability** | Unknown until done | Exact match (27/27) | Moderate | Predictable for planned expansions, bounded for adaptive |
| **Inspectability** | REPL output | Pipeline stages | Episode history | **Full causal graph with content-addressed facts** |
| **Adaptability** | High (model decides) | Low (fixed plan) | High (episodes) | Medium-high (typed expansion rules) |
| **Runtime** | Python REPL | Python + typed lib | Custom DSL | Elixir/OTP + Runic |
| **Durability** | None | None | None | Event-sourced via `Workflow.log/1` + Runner Store |
| **Distribution** | None | None | None | Runnables dispatch to remote executors |

### Runic's Unique Contributions

1. **Causal provenance at every level**: Every fact in the expanded graph traces back to its origin through content-addressed ancestry. No other RLM architecture provides this.

2. **Typed expansion with composition guarantees**: Sub-workflows are composed using the same type-safe primitives (Step, Rule, Map, Reduce, Join) as the parent. Expansion preserves the DAG property and causal consistency.

3. **Process-agnostic scheduling**: The same continuation workflow can execute in-process, across a Task pool, via GenServer workers, or distributed across nodes. The three-phase model decouples the what (workflow graph) from the how (execution strategy).

4. **Durable execution**: Workflow state is event-sourced. A continuation workflow that crashes mid-expansion can be recovered from `Workflow.from_log/1` and resumed. No other RLM system supports this.

5. **Livebook integration**: Visual inspection of the workflow graph at any point during execution. Human-in-the-loop review at continuation points. Live visualization of the expansion process.

---

## Concerns & Trade-offs

### Complexity Budget

Continuation workflows add significant conceptual complexity. The hook-based approach (Option C in API sketches) adds the least new surface area — it uses existing primitives (hooks, `Workflow.add`, `plan_eagerly`). A first-class `Runic.continuation` component (Option B) is cleaner but requires new Invokable, Component, and Activator implementations.

**Recommendation**: Start with the hook-based approach. Extract patterns into a first-class component only if the usage patterns stabilize.

### Graph Growth Bounds

A workflow that adds components during execution can grow unboundedly. Each expansion adds vertices and edges to the graph. Memory pressure is proportional to graph size.

**Mitigations**:
- Depth limits (hard cap on recursive expansion)
- Token/compute budgets (soft cap based on resource consumption)
- Sub-workflow isolation: execute sub-workflows to completion, collect their terminal facts, then GC the sub-graph. Only the results survive, not the full expansion tree.
- Structural bounds: if the decomposition is deterministic, graph size is predictable before execution.

### Serialization of Expanding Workflows

`Workflow.log/1` captures events for replay. Dynamically added components (from hook apply_fns) may contain closures that aren't serializable. This is the same problem as closure serialization in general — the `Closure` module's approach of capturing AST + bindings helps, but arbitrary hook functions may not be serializable.

**Mitigation**: Continuation workflows that need durability should use named, registered expansion strategies rather than anonymous closures:

```elixir
# Instead of:
{:apply, fn wf -> add_sub_workflow(wf, sub_wf) end}

# Use:
{:apply, {:expand, :map_reduce, chunk_specs}}
# ... where the engine knows how to interpret {:expand, ...} from registered strategies
```

### Coherence vs. Autonomy Trade-off

The more structure we impose (typed expansion, depth limits, structural decomposition), the less adaptive the system is. Lambda-RLM maximizes structure and gets predictable cost + quality. Standard RLM maximizes autonomy and gets unpredictable but flexible behavior.

Runic's position: **structure by default, autonomy by opt-in.** The recommended pattern is:

1. Use structural decomposition when the task shape is known (Lambda-RLM's insight)
2. Allow adaptive expansion (model-driven planning) when the task shape is unknown
3. Always bound adaptive expansion with depth/budget limits
4. Use causal ancestry + review steps for coherence checking

### Performance of Graph Operations

Adding components to a running workflow involves graph mutations (adding vertices, edges). With libgraph, these are O(V + E) in the worst case. For workflows that expand to thousands of nodes, this may become a bottleneck.

**Mitigation**: Batch expansions. Instead of adding one component at a time, construct the full sub-workflow and merge it in one operation. The `Workflow.merge/2` operation should be optimized for this pattern.

---

## Open Questions

### Q1: Should continuation be a new component type or a step return convention?

**Option A**: Return convention — any step can return `{:continue, sub_wf}`. The engine detects this in the apply phase. Minimal API change but implicit behavior.

**Option B**: Explicit component — `Runic.continuation(...)` with its own Invokable/Component/Activator implementations. More code but explicit contract.

**Option C**: Hook pattern — expansion is always done via after-hooks. No new component type. Most aligned with existing primitives.

**Recommendation**: Start with Option C (hooks), graduate to Option A (return convention) if the pattern proves universal.

### Q2: How should sub-workflow results wire into the parent?

When a continuation expands into a sub-workflow, the sub-workflow's terminal facts need to reach the continuation step's original downstream. Options:

**A**: Replace the continuation step with the sub-workflow (DPO rewrite). Clean but complex graph surgery.

**B**: Keep the continuation step, wire sub-workflow outputs as new inputs to it. The step executes again with the sub-result. Simple but creates a cycle risk.

**C**: Use a synthetic Join node that waits for all sub-workflow terminal facts, then forwards to the original downstream. Most aligned with existing FanIn/Join patterns.

**Recommendation**: Option C — it reuses existing Join semantics and avoids graph surgery.

### Q3: How to handle partial results on depth/budget exceeded?

When expansion is forced to stop before the goal is achieved, what should happen?

**A**: Error — `{:error, :depth_exceeded}` fact propagates.

**B**: Best-effort — force the current leaves to produce with whatever they have, fold results.

**C**: Checkpoint — persist the partial workflow for later resumption with more budget.

**Recommendation**: All three, controlled by a `:on_exceeded` option. Default to B (best-effort).

### Q4: Integration with Runic.Runner?

The Runner's Worker GenServer is the natural host for continuation workflows. The dispatch loop already handles prepare → dispatch → apply cycles. Continuation expansion would add a new phase: after apply, check for continuation results and expand before the next cycle.

Should the Runner be continuation-aware, or should continuation handling happen purely in the workflow layer (hooks + `react_until_satisfied`)?

**Recommendation**: Workflow layer first. The Runner should not need to know about continuations — they should be transparent through the existing dispatch cycle.

### Q5: Multi-model composition?

Slate observes that "cross-model composition works well — using Sonnet and Codex together." Runic's `run_context` naturally supports this:

```elixir
run_context: %{
  planner: %{model: "openai:o3", api_key: key1},     # strong reasoner for planning
  extractor: %{model: "anthropic:haiku", api_key: key2},   # fast model for leaf extraction
  generator: %{model: "anthropic:sonnet", api_key: key3}   # balanced model for synthesis
}
```

Each component gets the model appropriate for its role. Should this be a first-class pattern with ergonomic API support?

### Q6: How does this relate to the SubWorkflow component from future-component-exploration?

The SubWorkflow/Call Activity component (future-component-exploration.md §16) is related but distinct:

- **SubWorkflow**: a *static* invocation of a known workflow as a step. The child workflow is fixed at construction time.
- **Continuation**: a *dynamic* expansion where the child workflow is constructed at runtime based on execution results.

Continuations are a superset — a static SubWorkflow is a continuation that always returns the same expansion. Should they share an implementation?

### Q7: Relationship to the Feedback Controller pattern?

The Feedback Controller (future-component-exploration.md §15) shares the "inspect output, adjust behavior" pattern with continuation workflows. A continuation that checks output quality and re-expands is essentially a feedback controller where the "actuator" is workflow graph expansion.

Could a generalized Feedback Controller subsume continuation handling? The controller measures output quality (sensor), compares to goal (error), and adjusts the workflow (actuator — expand, retry, or accept).

---

## References

1. Zhang, A. & Khattab, O. "Recursive Language Models" (2024). https://arxiv.org/abs/2512.24601
2. Lambda-RLM. "λ-RLM: The Y-Combinator for LLMs" (2025). https://arxiv.org/abs/2603.20105, https://github.com/lambda-calculus-LLM/lambda-RLM
3. Galanos, T. "Recursive by Design" (2026). https://theharness.blog/blog/recursive-by-design/
4. Random Labs. "Slate: Moving Beyond ReAct and RLM" (2025). https://randomlabs.ai/blog/slate
5. Prime Intellect. "RLM Replication" (2025). https://www.primeintellect.ai/blog/rlm
6. Wolfram, S. "A New Kind of Science" (2002). Cellular automata and rule rewriting systems.
7. Wolfram, S. "A Project to Find the Fundamental Theory of Physics" (2020). Multiway systems, causal invariance.
8. Ehrig, H. et al. "Fundamentals of Algebraic Graph Transformation" (2006). Double-pushout (DPO) graph rewriting.
9. Beer, S. "Brain of the Firm" (1972). Viable System Model for recursive organizational structure.
10. Vanlightly, J. "Demystifying Determinism in Durable Execution" (2025). https://jack-vanlightly.com/blog/2025/11/24/demystifying-determinism-in-durable-execution
11. Vanlightly, J. "The Durable Function Tree" (2025). https://jack-vanlightly.com/blog/2025/12/4/the-durable-function-tree-part-1
12. Meijer, E. et al. "Functional Programming with Bananas, Lenses, Envelopes and Barbed Wire" (1991). Hylomorphisms as unfold-then-fold.
13. Cognition Labs. "Don't Build Multi-Agents" (2025). https://cognition.ai/blog/dont-build-multi-agents
14. Manus. "Context Engineering for AI Agents" (2025). https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus
