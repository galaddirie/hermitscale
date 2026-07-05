# Map/Reduce Region Redesign

**Status:** Implemented.
**Scope:** the fan-out → body → fan-in ("map/reduce region") subsystem — its nodes,
edges, events, completion semantics, runtime construction contract, and durable resume.

This document is the authoritative record of *why* the region subsystem looks the
way it does and *what contract* it now offers. It supersedes the map/reduce parts of
the earlier `eventsourced-implementation-plan.md` and `invokable-three-phase-refactor.md`.

---

## 1. Motivation

The consumer that drove this redesign is a **compiler, not a human**: it turns
declarative workflow-graph JSON (nodes + connections, often user-authored) into an
executable Runic workflow **at runtime**. Nodes, steps, and params are known only at
run time, and resume is done by **recompiling from the stored JSON and replaying the
event log**, never by serializing live structs.

The previous map/reduce implementation fought that use case in five ways:

1. **The expressive API was macro-only.** `Runic.map/reduce` pattern-matched step
   *AST shape* (`pipeline_workflow_of_map_expression` had one clause per shape). With
   steps that exist only as runtime values, that path was unavailable and the runtime
   API beneath it was effectively nonexistent for regions.
2. **`map → step → step → reduce` wasn't expressible** through the obvious public API,
   and the middle steps didn't behave as the topology implied.
3. **Per-element vs. aggregate execution was implicit and runtime-derived** — a
   `MapSet` of node hashes (`mapped.mapped_paths`) populated by an order-sensitive
   `FlowPath.flow_path(fan_out, fan_in)` snapshot taken *at reduce-connect time*.
4. **The map body's extension point was a private struct field** (`Map.pipeline`, a
   nested `%Workflow{}`) sitting beside parallel fields (`components`, `hash`, `closure`)
   that silently drifted when built programmatically.
5. **Fan-in wiring coupled to naming, ordering, and a `:leaf` marker** — `reduce(map:
   :name)` + a single `{map.name, :leaf}` lookup + an ordinal `Join.joins` list.

### Root cause

The region's *meaning lived in construction-order side effects and name lookups, not
in the graph.* Completion was reconstructed at run time from a side-table (`mapped`:
`expected`/`seen` maps) whose contents depended on when the reduce was connected. A
step off the snapshotted path, or a reduce connected before its body existed, silently
never completed.

The redesign inverts this: **the meaning of a region is carried by typed nodes, typed
edges, and fact ancestry — computed once at construction, queryable before execution,
and reconstructible from the event log.**

---

## 2. Design Principles

- **One primitive each.** A single fan-out node (`FanOut`) and a single fan-in node
  (`FanIn`), each with exactly one behavior. A node's behavior must never depend on
  *how* it was constructed.
- **Meaning in the graph.** Per-element scope and fan-in completion are functions of
  topology + fact ancestry, not of a build-order cache. No `mapped_paths`.
- **Structural binding.** A fan-in binds to its fan-out by an edge (`:fan_in`), not by
  a component name or a `:leaf` marker.
- **No bespoke events.** A scattered element and a reduce result are ordinary
  `FactProduced` events; there are no fan-out/fan-in event types.
- **Runtime-first.** The primary construction path is plain function calls over runtime
  values. The `Runic.map/reduce` macros are sugar that compile to the same graph.
- **Flat, not nested.** Region body steps are ordinary vertices in the one workflow
  graph. There is no nested-`%Workflow{}`-in-a-field for completion to depend on.

---

## 3. Node & Edge Vocabulary

### Nodes

| Node | Role |
|---|---|
| `Runic.Workflow.FanOut` (`[:hash, :name]`) | Splits an enumerable input fact into one fact per element. |
| `Runic.Workflow.FanIn` (`[:hash, :name, :init, :reducer, :map, mergeable, meta_refs]`) | Reduces the per-element results of a fan-out (or an enumerable from a single parent) into one fact. |

`Map` and `Reduce` remain as the *composable component wrappers* the macro emits
(`%Map{pipeline}`, `%Reduce{fan_in}`); their `Component.connect/3` flattens into the
same `FanOut`/`FanIn` + edges the runtime builder produces. They are construction
sugar only — no runtime completion logic reads them.

### Edges

| Label | From → To | Meaning |
|---|---|---|
| `:flow` | parent → child | Dataflow / scheduling. A fan-in is scheduled once per element result via a `:flow` edge from each body leaf. |
| `:fan_out` | fan-out → element fact | The structural record of an emitted element (drawn by applying `FactProduced{producer_label: :fan_out}`). Completion counts these. |
| `:fan_in` | fan-out → fan-in | **Structural binding.** How a fan-in finds its fan-out. Replaces the `map:` name + `:leaf` coupling. |
| `:reduced` | fan-in → result fact | The reduce output; also the idempotency marker (a batch is done iff a `:reduced` fact exists for its source). |
| `:produced` | step → result fact | Ordinary step output; body-leaf `:produced` facts are the fan-in's "arrived" set. |

### Fact metadata

Element facts carry, in `Fact.meta`:

```elixir
%{scatter: fan_out.hash, index: i, of: n}
```

- `index` makes reduce order **deterministic** regardless of arrival order or
  parallelism (the old prepend-then-`Enum.reverse` trick is gone).
- `of` is the batch size — a cheap completion target.
- The element fact's hash folds in `index` (`fact_hash({value, ancestry, index})`) so
  **duplicate element values remain distinct vertices** (a latent bug in the old model,
  where two equal elements collided on `fact_hash({value, ancestry})`).

---

## 4. Event Model

Two event types, both `FactProduced` (see `Runic.Workflow.Events.FactProduced`):

```elixir
# a scattered element, emitted once per item by FanOut.execute/2:
%FactProduced{
  hash: fact_hash({value, {fan_out.hash, source.hash}, index}),
  value: value,
  ancestry: {fan_out.hash, source.hash},
  producer_label: :fan_out,
  meta: %{scatter: fan_out.hash, index: index, of: n}
}

# the reduce result, emitted by FanIn's Coordinator.finalize/3:
%FactProduced{
  hash: ...,
  value: reduced,
  ancestry: {fan_in.hash, source.hash},
  producer_label: :reduced
}
```

`Workflow.apply_event/2` for `FactProduced` logs the fact and draws
`producer --producer_label--> fact` — so `:fan_out` and `:reduced` edges fall out of
the generic clause with no special-casing. There is no `FanOutFactEmitted`,
`MapReduceTracked`, or `FanInCompleted` (all deleted).

---

## 5. Completion by Ancestry

Completion lives in `Coordinator.finalize/3` for `FanIn` (`lib/workflow/fan_in.ex`).
It runs after the fan-in's per-element activation is consumed and recomputes readiness
**from the graph**, never from a side-table.

```
finalize(fan_in, wf, runnable):
  mode != :fan_out_reduce            -> {wf, []}      # simple reduce handled in execute/2
  fan_out  = in_edge(fan_in, :fan_in).v1              # structural binding
  source   = walk ancestry(arrival_fact) to the fact emitted by fan_out; its parent
  already reduced for source? (:reduced edge)         -> {wf, []}   # idempotent

  expected = |out_edges(fan_out, :fan_out) whose element ancestry parent == source|
  arrived  = terminal :produced facts of fan_in's :flow parents,
             correlated to an element of `source` by walking ancestry

  arrived == expected > 0 ->
    reduce (sort by meta.index) with reduce_with_context(meta ⊕ run_context)
    emit FactProduced{:reduced, ancestry: {fan_in.hash, source}}
    consume every sibling arrival's :runnable edge into fan_in
    activate downstream with the reduced fact
```

Key properties:

- **Build-order independent.** `expected`/`arrived` are read from `:fan_out` and
  `:produced` edges present at completion time; nothing depends on when the fan-in was
  bound. Binding the fan-in *before* the body exists still completes correctly.
- **Merge-safe.** Under parallel dispatch (invoke on a copy → merge), the element facts
  and leaf results accumulate in the merged graph; the fan-in completes when they're all
  present. Because a runner may dispatch the fan-in once per batch rather than once per
  arrival, `finalize` consumes **all** sibling `:runnable` edges on completion (not just
  the triggering one) so no stray runnables linger.
- **Two modes.** With no upstream fan-out (`:fan_in` in-edge absent), `FanIn` is a
  *simple reduce* of the incoming enumerable fact — handled in `Invokable.execute/2`,
  producing `FactProduced{:reduced}` directly. With a fan-out, `execute/2` only emits
  `ActivationConsumed` and the reduce happens in `finalize/3`.

`context/1` in reducers is preserved: `finalize/3` merges `meta_context` + `run_context`
and calls an arity-3 reducer when present. `mergeable` is retained on the struct/context;
index-ordered reduction is always valid, so it is a no-op optimization hint today.

---

## 6. Per-element Scope as a Query

Two pure functions on `Runic.Workflow` answer "what runs per element, feeding which
fan-out" **before execution**, from edges alone:

```elixir
Workflow.regions(wf)
# => [%{fan_out: %FanOut{}, fan_in: %FanIn{}}, ...]   # from :fan_in edges

Workflow.scope_of(wf, node)
# => {:element, fan_out_hash}   if node is on a :flow path from a fan-out to its fan-in
#  | :aggregate                 otherwise
```

This is the inspectable replacement for `mapped_paths`. It is derived, so it cannot be
corrupted by construction order, and it composes with nesting (scope is determined per
region boundary).

### Per-node input→output trace

`Workflow.trace/1` (and `trace/2` for one node) gives an n8n-style execution view,
built from one pass over the fact DAG:

```elixir
Workflow.trace(wf)          # => %{node_name => [%{input:, output:, index:}, ...]}
Workflow.trace(wf, :double) # => [%{input: 1, output: 2, index: 0}, ...]
```

Each entry is `%{input, output, index}`. Because a step inside a region runs once per
element, it simply yields one entry per item (with `:index` the fan-out element index);
a plain step yields a single entry with `index: nil`. This unifies "count/inspect
iterations" and "inspect a regular step" into one endpoint — no separate iteration or
count API. `:index` is resolved by walking a fact's ancestry to the nearest element fact
(`meta.index`); inputs/outputs are the fact values on either side of each `{producer,
input}` ancestry link. Node keys come from `node.name`, so naming nodes (the runtime
builder always does; the `map` macro names only the fan-out) yields a readable view.

---

## 7. Runtime Construction Contract (the compiler's API)

Build a region from **runtime values** — no macro, no AST:

```elixir
alias Runic.Workflow
alias Runic.Workflow.{Step, FanOut, FanIn, Root}

fan_out = FanOut.new(name: :nums)
double  = Step.new(work: fn x -> x * 2 end, name: :double)
inc     = Step.new(work: fn x -> x + 1 end, name: :inc)
fan_in  = FanIn.new(name: :sum, init: 0, reducer: &(&1 + &2))

wf =
  Workflow.new(:pipeline)
  |> Workflow.attach_fan_out(fan_out, to: %Root{})   # or to: parent_ref
  |> Workflow.add_step(fan_out, double)              # body via ordinary flow edges
  |> Workflow.add_step(double, inc)
  |> Workflow.attach_fan_in(fan_in, fan_out, from: inc)

wf |> Workflow.react_until_satisfied([1, 2, 3, 4]) |> Workflow.raw_productions(:sum)
# => [24]     # (1*2+1)+(2*2+1)+(3*2+1)+(4*2+1)
```

- `FanOut.new/1`, `FanIn.new/1` — construct nodes from values (`:reducer`, `:init`,
  `:name`, `:mergeable`, `:meta_refs`). Both implement `Runic.Component`.
- `Workflow.attach_fan_out(wf, fan_out, to: parent)` — places the fan-out and registers
  it.
- `Workflow.attach_fan_in(wf, fan_in, fan_out, from: leaf | [leaves])` — draws `:flow`
  from each leaf (scheduling) and the `:fan_in` binding edge (completion), and registers
  the fan-in. Multiple leaves are supported (a region body may have multiple terminals).

**Contract guarantees**, all enforced at construction rather than by convention:

- buildable from runtime values (no macro, no AST shape);
- a fan-in with one, non-build-order-dependent completion behavior;
- inspectable before execution (`regions/1`, `scope_of/2`);
- topological-emit friendly — bind the fan-in at any point relative to the body.

### Macro sugar

`Runic.map/reduce` and `Runic.workflow(steps: […])` are unchanged for callers and
compile, via `Component.connect/3`, to the *same* `FanOut`/`FanIn` + `:fan_out`/`:flow`/
`:fan_in` graph the runtime builder produces. `reduce(map: :name)` resolves the fan-out
by name only at connect time to draw the `:fan_in` edge; from then on the binding is
structural.

---

## 8. Durable Resume

Resume is recompile-from-JSON + replay, in-process. Because completion is a function of
the fact DAG:

- Scattered elements (`FactProduced{:fan_out}`, carrying `meta`) and reduce results
  (`FactProduced{:reduced}`) are ordinary events that serialize via ETF for free and
  fold through `apply_event/2` during `from_events/2`.
- **Full-log replay** onto a freshly recompiled structure restores the result.
- **Mid-region resume** works: replay a prefix that stops after the body but before the
  fan-in committed (drop the fan-in's own `FactProduced`/`ActivationConsumed`), then
  continue reacting — the fan-in re-derives completion purely from the replayed
  `:fan_out` edges and body `:produced` facts. No `mapped`/`mapped_paths` crosses the
  resume boundary. (See `test/workflow/region_test.exs`, "durable resume".)

---

## 9. What Was Removed

- `workflow.mapped.mapped_paths` and all reads/writes; the map-reduce keys in `mapped`
  (`{source, fan_out}`, `{source, step}`, `{:fan_out_for_batch, …}`,
  `{:fan_in_completed, …}`). `mapped` remains only for accumulator/state-machine keys.
- Step-side map-reduce tracking (`build_fan_out_context`, `is_reduced_in_map?`,
  `find_fan_out_info`, `store_fan_out_hash_for_batch`, `maybe_prepare_map_reduce`).
- Events `FanOutFactEmitted`, `MapReduceTracked`, `FanInCompleted` and their
  `apply_event/2` clauses/helpers.
- The `FlowPath.flow_path(fan_out, fan_in)` `mapped_paths` population in
  `Reduce.connect/3`, and the `mapped_paths` merge special-case.

Net change: **−415 lines**. The `:leaf` marker and `Reduce.connect`'s `map:` lookup
are retained *only* as connect-time conveniences for the macro; they play no part in
completion.

---

## 10. Invariants & Tradeoffs

- **Invariant:** a `FanIn` has exactly one completion strategy (ancestry). It is never
  "mapped-based if built one way, ancestry-based if built another." This is the core
  fix — a single node type with a single behavior.
- **Invariant:** `scope_of/2` is a function of edges only; equal for a given final graph
  regardless of construction order.
- **Tradeoff (cost):** `finalize/3` scans the fan-out's `:fan_out` edges and the leaves'
  `:produced` facts on each arrival — O(elements) worst case. The old code did
  same-order `MapSet` work plus ancestry walks; net neutral. `of` in `meta` allows an
  O(1) short-circuit if ever needed.
- **Tradeoff (ordering):** determinism now depends on `meta.index` being stamped by the
  scatter. This is intrinsic to `FanOut` and cannot drift; it is strictly better than
  the old emission-order-via-list-reversal, and it fixes duplicate-element identity.
- **Non-goal:** distributed live-struct handoff. Resume is in-process recompile+replay;
  correlation travels with fact ancestry + `meta`, which is sufficient for that model.

---

## 11. Test Coverage

- `test/workflow/region_test.exs` — runtime construction, per-element execution,
  `meta.index` ordering, duplicate elements, downstream aggregate step, `scope_of/2`,
  `regions/1`, build-order independence, and durable resume (ETF round-trip, full-log
  replay, mid-region resume).
- Behavioral macro contracts preserved unchanged across `workflow_test.exs`,
  `parallel_workflow_test.exs`, `three_phase_test.exs`, `mergeable_test.exs`,
  `compilation_utils_test.exs`, `run_context_test.exs`, and the `Runic.map/reduce`
  doctests.
- `parallel_workflow_test.exs` covers completion under parallel invoke + merge.
- White-box tests that asserted the removed mechanism were rewritten to assert the new
  one (element facts as `FactProduced{:fan_out}`, `:reduced` completion, `:fan_out`
  edges surviving merge) in `event_sourced_test.exs` and `parallel_workflow_test.exs`.

Suite: **55 doctests, 1343 tests, 0 failures.**
