# Workflow node authoring

Catalog nodes declare static metadata and implement `work/3`. The compiler
validates graph params, resolves collection scopes, and builds Runic components.
The domain uses `Join` to converge branches and `Collect` to close a map scope.
Ordinary callbacks use Runic's `SingleOutput` lifecycle for hooks, attempts,
failures, output facts, and accepted events.

```elixir
defmodule Hermitscale.Workflows.Nodes.Example.Scale.V1 do
  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "example.scale",
    version: 1,
    kind: :step,
    expr: [:factor],
    params: [factor: [type: :integer, default: 2]]

  @impl true
  def work(%{factor: factor}, value, %{context: context}) do
    value * factor
  end
end
```

Use `_context` when unused. Params are atom-keyed, defaulted, and expression
fields are resolved immediately before work. Node versions identify catalog
implementations; execution histories also require compatible callback code.
`build/2` is generated. Override it only for a specialized Runic component with
a different execution lifecycle, such as a rule.

## Kinds and collection scopes

| Kind | Execution |
| --- | --- |
| `:step` | One callback per input occurrence. |
| `:join` | Waits for one terminal outcome per declared input of the same occurrence. |
| `:map` | Opens a collection scope, then calls work for each list element. |
| `:reduce` | Closes the innermost map, folding successful items in source order. |
| `:aggregate` | Closes the innermost map, transforming and collecting successful items in source order. |
| `:rule` | Requires an explicit specialized `build/2`. |

Maps accept lists; nil represents an empty collection. A scalar is a
configuration error, reported as `{:expected_collection, value}`. Nested lists
are ordinary item payloads until another map explicitly opens a scope. Equal
values always remain distinct occurrences.

Branches can have different numbers of steps. A join must receive branches in
the same collection scope. Aggregate nested collections before joining them
with a branch in their enclosing scope. Every reduce or aggregate has one
structural parent and closes exactly the innermost map. Multiple structural
parents require an explicit join. Declared join inputs determine arity;
connections use unique contiguous `to_input` slots starting at zero.

```text
map orders
├─ enrich ────────────────┐
└─ validate → price ──────┤ merge → aggregate orders
                         ┘
```

Both branches converge separately for each order. A second map opens another
scope; its aggregation produces one collection payload for the enclosing item.
Parallel completion order never determines pairing or reduction order.

## Callback and expression contexts

Every callback receives its declared runtime dependencies plus `deps.context`,
a `Hermitscale.Workflows.Engine.Context`. The same view drives expressions.

| Callback field | Expression | Meaning |
| --- | --- | --- |
| `json` | `$json` | Value delivered to this callback. |
| `item` | `$item` | Original item of the innermost map, or current value outside a map. |
| `item_index` | `$itemIndex` | Zero-based position in the innermost map. |
| `ancestry` | `$ancestry` | Outer-to-inner map frames with map, batch, item occurrence, index, size, and original value. |
| `upstream` | `$node["id"]` | Relevant upstream output entries with `json` and occurrence identity. |
| `execution` | `$execution` | Input, root, runnable, activation and attempt identities, and attempt number. |
| `runtime` | — | Fresh component runtime dependencies; never automatically copied into expressions or facts. |

Expressions also have `$env`, `$vars`, `$workflow`, `$now`, and `$today`.
A reduce callback additionally receives `deps.acc` and `$acc`. Its runtime
context is resolved at execution, including after replay. Aggregate expressions
resolve per item before its result is collected.

`$node` references must name structural ancestors. References use local
occurrence history and do not introduce scheduling edges. After aggregation,
an ancestor with multiple contributing occurrences has an ordered list of
entries; select one explicitly, for example `$node["price"][0].json`. An
ancestor with one occurrence retains a single entry. This preserves collection
cardinality and avoids selecting a workflow-global latest result.

Declare runtime requirements through `requires`, for example
`requires: [credentials: [provider: "google", scopes: [...]]]`. Credentials
arrive separately as `deps.credentials`; selected connected accounts and trusted
execution authority are resolved before admission and refreshed on resume.
Do not capture runtime resources in node definitions or return them as data.

## Outputs, skips, and failures

An ordinary return is successful data, including `{:error, reason}`. For an
explicit failure, return `Runic.Workflow.SingleOutput.Result.failure(reason)`;
exceptions also fail the attempt. Runic owns bounded retries, timeouts, and
backoff. Node work must not implement another retry loop.

Return `{:skip, reason}` for an intentional skipped occurrence. A graph policy
with `on_failure: "skip"` converts exhausted attempts into a durable skipped
outcome. Skips propagate along that item's branch without suppressing siblings.
Halting failures fail the run. Strict joins reject skipped inputs with a
`missing_join_inputs` failure; merge nodes can opt into `on_missing: "nil"` or
`"omit"`. The former retains input positions; the latter removes skipped
inputs before combining. Collection modes treat explicitly missing branches as
empty lists, so zip modes can pad their rows. Successful payloads must still be
lists; a successful nil payload fails collection-mode validation.

A reduce omits skipped items and returns its static `initial` seed for an empty
collection. An aggregate omits skipped items and returns `[]`. Empty collections
carry internal completion markers so nested scopes and joins can close;
markers bypass callbacks and are excluded by `Engine.productions/2` and durable
run outputs. Idle runs with unfinished joins or collectors fail explicitly.

## Builtin merge modes

`merge` waits for correlated terminal branch outcomes. Mode selection controls
payload combination and never aligns separate mapped occurrences.

| Mode | Result |
| --- | --- |
| `append` | Ordered branch values, retaining list payloads as lists. |
| `combine` | Shallow map merge; later maps win. Non-map values contribute no fields. |
| `zip_nil` | List rows up to the longest input, with nil padding. |
| `zip_shortest` | List rows up to the shortest input. |
| `zip_cycle` | List rows up to the longest input, cycling shorter lists; empty lists contribute nil. |
| `cartesian` | All ordered combinations of input list elements. An empty input yields `[]`. |
| `flatten` | Concatenates list inputs by one level, preserving nested items. |

For `zip_nil` and `zip_cycle`, all-empty inputs yield `[]`. Scalars passed to
collection modes fail with a clear list-input error. List payloads are never
inferred to mean streams or recursively flattened.

## Identity, metadata, and replay

`Fact.value` remains the payload. `Fact.meta.hermitscale` holds durable root and
item correlation, nested scope frames, upstream history, and contributor IDs.
Identity derives from native Runic occurrence coordinates, including indexed
fan-out. Branches preserve item identity; convergence records every contributing
fact; aggregation pops one frame while retaining contributing history.

Retries keep item and activation identity while exposing a different attempt
identity. Replay folds accepted metadata-bearing events without rerunning
accepted callback effects. It supplies fresh runtime resources to remaining
work. External effects are not automatically exactly once: a crash between an
effect and durable acceptance can repeat that effect.

To add application metadata, return `SingleOutput.Result.value(value,
metadata: %{application_namespace: data})`. Engine correlation and native
coordination namespaces are reserved. Metadata accepts durable data and native
identity structs, rejects runtime references and authority structs, and is
persisted through native `FactProduced` events. Never put secrets, clients,
process handles, scopes, or credential references into metadata.

Recovery compares the compiled definition fingerprint before accepting events.
Callback compiled-code digests and declared runtime requirements participate in
node identity. Changed topology, callback code, identities, policies, or authored
ambient expression data reject old history. No compatibility transformation is
performed.

## Verification

Exercise node work directly for domain operations and run compiled graphs for
collection, context, policy, and replay behavior. Use `Engine.productions/2` for
application-visible outputs. Native `Workflow.productions/2` exposes all facts,
including internal outcomes, for lineage inspection. Parallel tests should vary
result application order, use equal payloads, and assert occurrence correlation.
Run `mix precommit` after changes.
