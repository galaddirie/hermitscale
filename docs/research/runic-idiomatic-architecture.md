# Hermitscale with deeper, idiomatic Runic usage

Research snapshot: October 11, 2026. Upstream inspected at commit [`6e6373832c00aa9ec5d19faeae945b61e2db50b1`](https://github.com/zblanco/runic/tree/6e6373832c00aa9ec5d19faeae945b61e2db50b1), from `/tmp/hermitscale-runic-upstream-20261011`. Local evidence includes existing uncommitted application changes; nothing in those changes was reverted. This is an independent architecture assessment, not an implementation or an approved migration decision.

## Conclusion

**Recommendation:** upgrade compatibility and recoverability first; then replace Hermitscale's special collection lowering with public Runic composition if executable parity tests pass. Keep the product's graph format, catalog metadata, sandboxed expressions, organization authorization, credential resolution, trigger admission, and Postgres persistence. A deeper integration can reduce engine knowledge in the compiler and make custom nodes more capable without turning every product concern into a Runic concern.

Hermitscale already uses `Runic.Runner` as its workflow scheduler. `Application` supervises it directly and `Workflows.start_run` calls `Runner.start_workflow` / `Runner.run` ([application.ex](/Users/galdirie/code/hermitscale/lib/hermitscale/application.ex:16), [workflows.ex](/Users/galdirie/code/hermitscale/lib/hermitscale/workflows.ex:125)). The local `Triggers.Scheduler` discovers due database rows and enqueues Oban jobs; it does not dispatch Runic runnables ([scheduler.ex](/Users/galdirie/code/hermitscale/lib/hermitscale/triggers/scheduler.ex:53)). Deleting it would remove product behavior rather than eliminate a competing workflow engine.

**Important limit:** upstream is not evidence that all fan-in problems are solved. Its ordinary-node collection tracking is substantially more capable, but its guide explicitly excludes redesigning empty batches, invocation-scoped batch identity, and arbitrary nested collectors ([custom-components.md lines 153–165](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/guides/custom-components.md#L153-L165)). In addition, mapped FanIn finalization still invokes a reducer with two arguments while `Runic.reduce` compiles context-using reducers with three. Preserve the current reducer workaround until a regression test establishes support or upstream repairs it ([fan_in.ex](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/fan_in.ex#L72), [runic.ex](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/runic.ex#L3790), [run_context_test.exs](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/test/workflow/run_context_test.exs#L1139)). The independent patch reviewer executed the native mapped-context probe: the vendored engine returned the expected result (60), while main raised `BadArityError`. The collected path therefore has a confirmed gap despite simple eager-reduce context support.

## What the application currently does

The compiler validates JSON, sorts topology, casts node parameters, adds policies, and adds expression-reference dependencies. For collections it identifies a linear map region, consumes its body nodes, builds prepare → FanOut → mapper → body → FanIn, and tracks aliases for later joins ([compiler.ex](/Users/galdirie/code/hermitscale/lib/hermitscale/workflows/compiler.ex:24)). The body is restricted to steps, one parent, one child, with no arbitrary cross-node references ([validator.ex](/Users/galdirie/code/hermitscale/lib/hermitscale/workflows/validator.ex:520)).

`Nodes.Behaviour` owns a useful application contract: versioned node metadata, parameter schemas, declared expressions and dependencies, generated Runic closures, and `work(params, input, deps)`. It does not independently run retry loops or construct Runic lifecycle events. For map it normalizes with `List.wrap`, pairs items with explicitly referenced upstream values, and emits bare outputs. For reduce it extracts `reduce.fan_in` and captures ambient expression data because coordinator reduction has no context argument ([behaviour.ex](/Users/galdirie/code/hermitscale/lib/hermitscale/workflows/nodes/behaviour.ex:107)).

The expression design document describes an old accumulating envelope, but current code reconstructs a transient `$json` / `$node` view from actual parents and explicit reference edges. Treat code and tests as current evidence, not every draft design statement ([expr.ex](/Users/galdirie/code/hermitscale/lib/hermitscale/workflows/expr.ex:169), [compiler.ex](/Users/galdirie/code/hermitscale/lib/hermitscale/workflows/compiler.ex:147), [draft expression document](/Users/galdirie/code/hermitscale/docs/design/workflow-expression-system.md:96)).

Runtime ownership is already sensibly divided: graph and run rows are application records; Runic executes; `PostgresStore` atomically appends ordered event rows; `Credentials` creates component-scoped run context after checking the graph's organization; trigger dispatch adds provenance, source-event deduplication and graph-level run admission ([postgres_store.ex](/Users/galdirie/code/hermitscale/lib/hermitscale/workflows/postgres_store.ex:63), [credentials.ex](/Users/galdirie/code/hermitscale/lib/hermitscale/workflows/credentials.ex:39), [dispatcher.ex](/Users/galdirie/code/hermitscale/lib/hermitscale/triggers/dispatcher.ex:1)).

## A small interface with deeper implementation

These are proposed module responsibilities, not additional wrappers to create mechanically:

| Module / interface | Behavior it owns | Behavior delegated to Runic |
|---|---|---|
| `Workflows` public context | Organization-scoped graph/run operations, start, resume, inspect, cancel/continue, product status | Runner lifecycle and admission |
| `GraphPlan.compile(definition)` → executable definition + logical-node mapping + output selection | Catalog resolution, product validation, expressions, policy normalization, graph-schema migration | Composition, named connection validation/lowering, Map/Reduce topology |
| Existing `Catalog` / node author contract | Stable type/version, UI schema, provider scopes, executable semantic configuration | Ordinary executable node preparation, Fact ancestry, activation events, hooks, collection tracking |
| `RunContext.resolve(scope, revision, run)` | Organization ownership, credential references, fresh runtime resources, expression ambient data | Component-scoped/global context lookup and required-key validation |
| `PostgresStore` | Transactions, ordered event persistence, queryable metadata, retention, optional snapshots/payload storage | Replay and snapshot formats through public interfaces |
| `RunProjection` within `Workflows` until it earns a separate module | User-visible statuses, logical-node outputs, progress summaries, persistence acknowledgements | Native lifecycle/hook/telemetry observations |

The compiler should return one useful artifact rather than force every caller to know helper node names, fan-out hashes, collector origins, and output extraction rules. That is the deep-module opportunity. Keep internal implementation helpers private unless two real adapters vary at their seam. A node-to-internal-components mapping is justified because the editor and execution inspector both need it.

**Proposed vocabulary:** a *Graph* is the editable product definition; a *Revision* is its immutable published version; a *Run* is one execution against one revision; a *Node* is the logical catalog instance; an *Activation* is one Runic execution occurrence; a *Collection region* is per-element execution plus its designated collector. These terms are proposals and have not been inserted into the project's existing identity glossary. They prevent conflating one UI node with one Runic Runnable or assuming the same payload means the same occurrence.

## Collections and joins

**Preferred lowering to prove:** preserve the normalization prepare step, then compose a native `Runic.map` whose pipeline contains the mapper and linear body, followed by a complete `Runic.reduce(..., map: map_name)` attached through `Workflow.add`. Stop extracting `.fan_in` or requiring custom `attach_fan_out` / `attach_fan_in` helpers. Public Map supports a pipeline; Reduce supports attachment after a downstream step using the named map ([runic.ex Map/Reduce](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/runic.ex#L3605), [component.ex](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/component.ex#L456)). Upstream handles mapped-path registration internally and recognizes Reduce outputs when composing downstream joins ([component.ex Step connection](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/component.ex#L623)).

**Alternative when runtime topology is necessary:** a product collection composite can use public composition and explicit structural FanOut/FanIn edges, with ordinary nodes relying on upstream shared collection tracking. Upstream exercises duplicate values, an intervening ordinary transformation, fallback outputs, and lightweight ancestor references through such topology ([single_output_collection_test.exs](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/test/single_output_collection_test.exs#L10)). This can avoid patches, but still retains low-level topology knowledge; native Map/Reduce is the shallower caller interface when it covers requirements.

Retain product semantics deliberately: only lists fan out; scalar/map becomes one item; nil becomes none. Native Map accepts enumerables, which is a different contract. Current tests also define empty mapped reduce as *no output*, not the initial seed ([edge tests](/Users/galdirie/code/hermitscale/test/hermitscale/workflows/nodes/primitives_edge_cases_test.exs:102), [empty reduce test](/Users/galdirie/code/hermitscale/test/hermitscale/workflows/nodes/primitives_edge_cases_test.exs:134)). Do not silently change either while upgrading.

Do not relax all region restrictions because Runic has richer composition. Branched per-item joins require a defined correlation rule; filters require a decision whether a rejected item counts as collected; nested regions require an owner for each batch and an output cardinality. The upstream ordinary-component guide does not promise those redesigns. Introduce one topology class at a time after behavioral tests. Equal elements, equal transformed outputs, repeated input batches, two simultaneous batches, and a join of reduced output with a sibling branch are the cases that discriminate true support from a happy-path demonstration.

## Node author contract and named ports

For existing uncomplicated nodes, native Steps are idiomatic and already adequate. Do not migrate every node to a struct merely to use a new feature. For nodes where stable identity, versioned configuration, port schemas, explicit failure, metadata and replay deserve their own representation, **recommend** an application-owned catalog component struct implementing `Runic.Component` and `SingleOutput.run/3`. Keep ordinary authors close to `spec/0` plus `work/3`; let one catalog builder or executable component hide Runic protocols, expression resolution and result conversion. `SingleOutput` removes lifecycle/event coordination from callbacks but deliberately leaves composition and reconstruction to `Component` ([custom component guide](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/guides/custom-components.md#L1), [SingleOutput](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/single_output.ex#L1)).

Explicit success/failure is useful for HTTP/provider nodes. Today HTTP raises a string for errors; a component could return `Result.failure(reason)` so retry classification preserves structured errors. Preserve compatibility: native Steps treat `{:error, reason}` as successful data; introducing typed results without migrating nodes and tests would change behavior. `Result.value({:error, reason})` and `Result.failure(reason)` intentionally mean different things ([guide data versus failure](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/guides/custom-components.md#L98), [HTTP node](/Users/galdirie/code/hermitscale/lib/hermitscale/workflows/nodes/builtin/http_request/v2.ex:28)). Node configuration and callback code version must participate in semantic identity; a module name alone does not pin deployed behavior.

A v2 graph format could promote connections from integer `to_input` ordering to named input/output ports plus safe selectors and assembly paths. Runic's `Connection` stores authored intent, validates connection groups, and lowers input projection into `InputBinding`, ordered by declared target ports ([connection.ex](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/connection.ex#L1), [input_binding.ex](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/input_binding.ex#L1)). This removes bespoke projection/assembly code for static bindings; it does **not** replace Liquid filters, interpolation, `$acc`, clock namespaces, or all cross-node expressions. Map external strings to declared trusted port atoms rather than create atoms from user input.

Keep `$node` references causal and explicit. A global “latest output of X” lookup can join the current item to another activation's value. Named connections can encode static dependencies and selected paths; arbitrary expression dependencies still need an input contract and validation. Do not replace them with a mutable output cache.

## Runtime context, persistence, and scheduling

Keep clients, provider credentials, repositories, process handles and pools out of component definitions and output metadata. Upstream `SingleOutput.Context` provides component runtime context and occurrence/attempt identities; resolve resources at start and again on resume ([context.ex](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/single_output/context.ex#L1)). Use stable credential references resolved by provider clients for long runs; the current connected-account path already returns references. Do not capture secrets or all `$env` data in a reduce closure just to work around context limitations. Capturing known nonsecret static variables may remain a temporary compatibility measure.

**High-priority recommendation independent of deep refactor:** persist an immutable graph revision and engine/code compatibility marker per run. Current resume recompiles `run.graph.definition`, which can be edited after execution began ([workflows.ex](/Users/galdirie/code/hermitscale/lib/hermitscale/workflows.ex:163)). A replay baseline must match the definition that generated accepted events. Preserve legacy runs through a versioned recovery path or drain them before changing identities/event interpretation; raw BEAM term decoding is not a semantic migration strategy.

**Second independent priority:** distinguish computation completion from durable completion. `mark_run_complete` marks and broadcasts completion; upstream explicitly invokes `on_complete` even when the final save failed. Use an observer notified by worker hooks, then query/checkpoint after the callback returns, and only publish durable completion after Store acknowledgement. Upstream warns against synchronously querying the same Worker inside its hook ([workflows.ex](/Users/galdirie/code/hermitscale/lib/hermitscale/workflows.ex:198), [durability guide](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/guides/durable-execution.md#L402)). Add product states for failed/stopped, uncertain effects and pending persistence; idle is not necessarily business success.

`PostgresStore` is a legitimate adapter to retain. Later add `stream/3` tail reads, snapshots, and fact/payload offloading when measured event volume or replay latency justifies them. Upstream defines optional interfaces for all three; they do not erase the need for transactions or retention ([store.ex](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/runic/runner/store.ex#L1)). Neither replay nor task cancellation guarantees exactly-once external HTTP effects. Use downstream idempotency keys derived from the stable business operation/activation, not retry attempt number. Test accepted-effect replay separately from effects whose response was lost.

Start with the default scheduler. Benchmark `ChainBatching` for short pure chains and `FlowBatch` for large independent fan-outs. Parallel promises have internal concurrency and reply with a batch; worker `max_concurrency` counts scheduler units, not necessarily provider calls. A provider rate limit therefore needs its own admission control or executor. Batching also enlarges the uncertain-effects window if an outer task loses its reply ([execution strategies](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/guides/execution-strategies.md#L140), [scheduling failure scope](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/guides/scheduling.md#L595)).

Reasons for a custom Runic scheduler/executor **if demonstrated**: organization fairness, provider quotas, remote execution, explicit state-application order, bounded memory, or persist-before-dispatch requirements. Keep these behind upstream scheduler/executor interfaces. None alone requires forking Fact propagation or reimplementing Join/FanIn. The local wall-clock trigger scheduler should remain for schedule occurrence transactions, catch-up policy, enablement and source deduplication; Runic dispatch scheduling serves a different purpose.

## Opportunities beyond a DAG of transforms

1. **Rules / conditions:** express routing, gating and policy checks as native rules, with the predicate evaluated against sandbox-resolved parameters rather than compiling arbitrary user Elixir. False conditions should be visible as intentional nonmatches, not failed HTTP work. Collection filtering semantics must be proven before allowing a rule inside collected regions.
2. **Reusable workflows:** expose nested workflows with explicit ports as reusable catalog capabilities. Upstream stores nested definitions including ports and ordered construction events, instead of treating their name as sufficient for replay ([definition.ex](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/definition.ex#L1)). This could encode reusable “fetch paginated records → normalize → write rows” behavior behind a smaller editor interface.
3. **Accumulators / state machines:** running totals, threshold alerts, event correlation, approval state. A current Run is created per trigger firing, so state does not automatically span firings. Long-lived workflow instances need explicit instance identity, tenant ownership, concurrency and retention decisions.
4. **Sagas / process managers (research only):** potential compensated multi-provider operations or event-driven business processes, subject to the source implementation caveats below. Do not assume durable transaction checkpoints or functional ProcessManager timers. A Saga cannot manufacture an undo operation for an irreversible API. Aggregate is appropriate for command/event/state modeling; it should not duplicate the existing database ownership model merely because it is available ([state component guide](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/guides/state-based-components.md#L26)).

These are product opportunities, not a claim that Runic adds all of them only now; several exist in the vendor already. Prioritize rules and reusable workflows over an unrequested event-sourced rewrite of application entities.

## Editor and inspector consequences

There is no workflow editor LiveView in the inspected current web tree; these are proposed product implications. Show logical nodes and named ports; hide prepare, input-binding and coordinator nodes by default, with an advanced engine graph view. Display item cardinality, collection owner, and whether a connection supplies data or expression context. Validate selections and expression references at save time, retaining application-specific issue paths. Make run inspection activation-aware: one node may have many items/attempts; distinguish successful output, nonmatch, skip, failure, uncertain effect, and unsaved progress. Redact credentials and runtime resources.

Output contracts can be declared explicitly rather than inferred forever from graph leaves. Upstream `Workflow.results` supports named output bindings/cardinality, but its default selects the last value. Current Hermitscale persists *all* terminal productions keyed by node ID; use `all: true` or explicit many cardinality to preserve behavior ([results implementation](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow.ex#L3203), [terminal_outputs](/Users/galdirie/code/hermitscale/lib/hermitscale/workflows.ex:228)).

## Deletion / retention map

| Existing area | Proposed disposition |
|---|---|
| Vendored `attach_fan_out` / `attach_fan_in` and custom mapped tracking | Delete after native Map/Reduce or supported composite parity tests pass; do not keep empty compatibility helpers |
| Compiler map-region body consumption / output aliases | Simplify into public composite construction; retain product region validation until richer topologies pass |
| Reducer compile-time ambient workaround | Retain temporarily; delete only when mapped reducers receive scoped runtime context correctly |
| `Nodes.Behaviour` catalog/schema contract | Retain; shrink generated lifecycle-specific plumbing, optionally target a shared SingleOutput component |
| `Expr`, filters, Params, provider requirements, organization validation | Retain; these encode product semantics absent from Runic |
| Static port/value projection plumbing | Replace where named Connections express it accurately |
| `PostgresStore`, graph/run schemas, trigger runtimes, Oban scheduler | Retain; evolve recovery/acknowledgement/retention contracts |
| Run completion observer and inspector | Strengthen around native statuses and persistence rather than add a second dispatch loop |

## Two migration paths and acceptance gates

**Conservative upgrade:** pin upstream, adapt changed identities and removed helper calls, preserve graph v1/node work contracts, keep residual compatibility logic outside upstream if possible, drain or version-route old runs. Gains are engine fixes and supported lifecycle behavior with limited product change. Costs are retaining some compiler complexity and region limits.

**Deeper refactor:** after parity, make the compiler emit public composites; adopt explicit component configuration/result semantics where valuable; introduce graph v2 named ports and revisioned output contracts; add reusable workflow and rule catalog entries. Gains are smaller engine-aware code surface, better inspection and composition. Costs include graph migration, callback/version compatibility, inspector mapping, and new behavioral contracts. Neither option supports promising arbitrary nested workflows or exactly-once effects without evidence.

Suggested sequence:

1. Freeze representative graph-v1 fixtures and recorded events with exact vendor/code versions. Inventory active/incomplete runs and documented semantics.
2. In an isolated experiment, use the pinned upstream with the same fixtures; execute parity tests for the mapped-context gap and every patched behavior. Record failures before changing design.
3. Pin immutable run revisions and make completion persistence-aware; these are worthwhile even if the vendor remains.
4. Replace one linear map/body/reduce lowering with native composition. Maintain expressions, list normalization, policies, terminal output shape and credential scoping. Compare accepted facts/results, not unstable internal hash values alone.
5. Remove each patch only when its behavioral test passes in the supported path. Submit remaining engine gaps upstream rather than burying them under a general rewrite.
6. Pilot explicit ports/SingleOutput on one real provider node; prove old `{:error, reason}` data behavior and new explicit failures are intentional.
7. Add rules/reusable workflows. Benchmark scheduler choices with realistic latency, payload sizes and provider quotas. Relax topology restrictions only for proven cases.

Discriminating tests, rather than implementation-mirroring tests:

- `[1, 1, 2]` and different inputs mapping to identical values retain multiplicity; string concatenation preserves source order under out-of-order task completion.
- Empty map, nil, scalar and map input retain current normalization/output behavior; two identical batch submissions and two concurrent batches never mix collection state.
- A reduced branch plus sibling branch joins once with correct values; explicit `$node` references select the current causal ancestor across items and runs.
- Map body fallback counts as a result; skip/halt/false-rule behavior cannot leave an unexplained permanent collector wait.
- Mapped reducer receives runtime `$env`/`$vars` and declared dependencies; secrets are absent from construction logs, events and outputs; resume receives fresh credential references.
- Compile a graph, start it, edit the graph, then resume: accepted events replay against the original revision.
- Crash after accepted work; lost executor reply; partial promise completion; durable append failure; retry append and stop. No false durable-complete notification, no discarded pending events, known effect repetition classified explicitly.
- Replay named connections and nested definitions with unchanged port/cardinality behavior; downstream outputs contain only selected logical outputs.
- Default, inline, chain and parallel schedulers yield equivalent domain results where order independence is declared; provider concurrency stays within the configured external limit.

## Method and uncertainty

Read current compiler, validator, node builders, expression implementation, credential/runtime paths, store, trigger scheduler/dispatcher, application supervision, and relevant tests. Read pinned upstream composition, custom-component lifecycle, context/reduce execution, named connections, nested definition, Store and scheduler guides/tests. No application code was changed and no architecture decision was made.

The code-quality skill baseline was run: it reported 55 issues across 28 files, including duplicated `child_map/1` between Compiler and Validator. Its unused-function analysis misidentifies names containing `!`/`?`, so that count is not a validated refactoring backlog. Do not remove functions based on it. No major refactor or new tests were performed by this review.

Uncertain assumptions: real workload sizes and provider quotas; number of active legacy runs; whether richer collection topology is a product requirement; desired lifetime/identity for stateful workflows; whether every intended custom Runner/executor combination preserves mapped reduction behavior beyond the confirmed native context failure. Each has an acceptance gate above. The browser could not fetch pinned GitHub pages (503); source claims were verified against the supplied pinned checkout and linked to its exact GitHub commit, not inferred from main-branch marketing text.

## Concrete lowering with main-supported composition

Representative product graph: `source → map(price) → normalize → reduce(total)`, with `source → count` as a sibling branch, followed by `merge(total, count)`. Map processes each order; normalize runs per order; reduce produces one total; merge waits for the total and count. A graph-v1 merge still receives `[total, count]` according to ordered `to_input` slots.

The following is a **source-supported blueprint, not an executed application migration**. The catalog continues to supply expression-resolving Steps/closures and list-normalizing preparation. The Runic construction itself needs no engine patches:

```elixir
require Runic
alias Runic.Workflow

source = Runic.step(fn input -> input end, name: "source")
prepare = Runic.step(fn value -> List.wrap(value) end, name: "price$prepare")
price = Runic.map(fn order -> order["price"] end, name: "price")
normalize = Runic.step(fn price -> price * 100 end, name: "normalize")
total = Runic.reduce(0, fn cents, acc -> cents + acc end,
  name: "total", map: "price")
count = Runic.step(fn orders -> length(orders) end, name: "count")
merge = Runic.step(fn values -> values end, name: "merge")

workflow =
  Workflow.new(name: "order_summary")
  |> Workflow.add(source)
  |> Workflow.add(prepare, to: "source")
  |> Workflow.add(price, to: "price$prepare")
  |> Workflow.add(normalize, to: "price")
  |> Workflow.add(total, to: "normalize")
  |> Workflow.add(count, to: "source")
  |> Workflow.add(merge, to: ["total", "count"])
```

A statically authored equivalent may put normalize inside `Runic.map`'s pipeline. For runtime JSON graphs, ordinary `Workflow.add` calls after the Map are easier than building arbitrary macro AST; the named `map:` reference on Reduce attaches to that map's FanOut. That path is explicitly implemented for a downstream Step ([component.ex lines 495–509](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/component.ex#L495-L509)). Do not `Code.eval_quoted` user-authored Elixir as a compiler shortcut. Maintain logical names and scoped policies, which need special verification because native Map has its own mapper name conventions.

For graph v2, declare trusted output/input ports on the relevant Steps and use connection groups, for example `connections: [[from: {"total", :out}, to: :total], [from: {"count", :out}, to: :count]]` on a target declaring inputs in `[:total, :count]` order. A two-arity Step then receives two arguments through native invocation; a one-argument product node may retain an assembled input list/map. `Runic.Connection` provides projection and assembly, while the catalog defines the expected domain shape. Start with the positional v1 path above; native Map/Reduce advertised schema options alone do not prove every port-routing composition is ready ([runic.ex Reduce options](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/runic.ex#L3772)).

**Strongest case for retaining the fork during qualification:** existing product fixtures already encode deliberate scalar/empty/output semantics; current compilation depends on helpers absent from main; active event logs may contain vendor identities; and main still has the mapped-context coordinator gap. The parent review executed an isolated baseline `mix precommit` with **298 tests, 0 failures**, and a direct upstream replacement produced **22 failures in 30 targeted application tests** because required helper/constructor calls disappeared. Those are compatibility results, not proof that native public composition cannot satisfy the product. They justify retaining a pinned fork while testing a separate native lowering, instead of switching production dependencies first and repairing execution semantics afterward.

Native Steps remain the default. A custom SingleOutput component earns its extra protocol/identity/reconstruction work only if it removes *real* per-node lifecycle duplication or gives the application explicit failure/metadata/versioned configuration that Steps cannot express cleanly. The current catalog already centralizes much of this; maximum custom-component adoption would add more interface for little benefit. One shared catalog executable struct can be evaluated on a real provider node, but a distinct new Runic struct per simple arithmetic node is not warranted.

## State-component qualification caveats

Source inspection tempers the state-component opportunity list. Saga's current macro constructs one accumulator reducer that performs the forward sequence internally; compensation iterates keys from the results map and rescues compensation errors. Do not assume independently checkpointed transactions, guaranteed reverse-declaration compensation, or durable progress between each external effect merely from the guide description ([runic.ex saga construction](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/runic.ex#L1819), [compensation implementation](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/runic.ex#L2005)). ProcessManager parses timeout handlers and records their count, but the constructed event rules/workflow do not include executable timeout-handler bodies ([runic.ex lines 2735–2788](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/runic.ex#L2735-L2788)). Keep Oban/trigger timers for actual scheduling. Treat both features as experiments behind source-level and failure/recovery tests, not an immediate replacement for existing durable orchestration.

## PR #43: an optional observation-based runtime design

The user additionally requested assessment of open [PR #43](https://github.com/zblanco/runic/pull/43). Its separately inspected head is [`d1cd8c6863e89d9742bcd54af44c95097064ce4d`](https://github.com/zblanco/runic/tree/d1cd8c6863e89d9742bcd54af44c95097064ce4d), at `/tmp/hermitscale-runic-pr43-20261011`. **This design is PR-dependent and unmerged; it is not a capability of the main snapshot above.** Its branch also incorporates unmerged failure-suppression changes associated with PR #42, so pin and qualify the combined behavior rather than attribute all changes to #43.

PR #43 supplies `Workflow.execute/3` returning `{workflow, Execution}` and Runner `start_execution`, `execution`, `await_execution`, and `forget_execution`. `Execution` models one explicit input occurrence, scoped active/ready units, accepted outcomes, admission, quiescence and persistence observations. `Outcome` separates completed, failed, skipped, and uncertain work with execution/activation/attempt identities and observed acceptance sequence. Equal repeated input values get different generated input occurrences; stable consumer ordering is separate from observed completion order ([execute](https://github.com/zblanco/runic/blob/d1cd8c6863e89d9742bcd54af44c95097064ce4d/lib/workflow.ex#L3359), [Execution](https://github.com/zblanco/runic/blob/d1cd8c6863e89d9742bcd54af44c95097064ce4d/lib/workflow/execution.ex#L1), [Outcome](https://github.com/zblanco/runic/blob/d1cd8c6863e89d9742bcd54af44c95097064ce4d/lib/workflow/execution/outcome.ex#L1), [Runner interfaces](https://github.com/zblanco/runic/blob/d1cd8c6863e89d9742bcd54af44c95097064ce4d/lib/runic/runner.ex#L159)).

**Recommended optional runtime shape if qualified:** `Workflows.start_run` creates the durable product Run/revision, starts its Runner Worker, then calls `Runner.start_execution` with a typed identity derived from that Run's ID. Store the encoded identity alongside the product Run. An observer maps `Runner.execution` into node/item progress and business status; `await_execution` powers integration tests and explicit server-side waits; a sandboxed preview uses `Workflow.execute` with fake provider dependencies. Forget process-local observations after persisting the needed application projection and releasing UI subscribers. Keep one Worker per current product Run: only one observed scope can progress in a Worker at a time, which is compatible with one trigger firing per Run. Long-lived multi-input stateful instances need a separate admission design.

This is a materially better debugger interface than inferring failure from lack of productions or assuming an idle Worker means success. It also makes uncertainty a first-class observed condition. The existing main-supported design can still obtain statuses through Runner admission/persistence APIs and event projections; #43 reduces that adaptation work but is not required to remove collection patches.

Verified limits that affect the proposed product interface:

- **Quiescence is not success or durable completion.** It includes stopped admission with retained ready work, and `await_execution` may return while persistence is pending or failed. Compute product status from outcomes/admission and acknowledged Store state separately.
- **Observation is process-local.** `Execution` records are held in Worker memory; restarting/replaying the workflow does not reconstruct an identical observation. Persist essential historical status and node progress in an application projection or recreate them from accepted durable events. Avoid serializing the entire Execution as an assumed replay contract.
- **Old persistence snapshots become stale.** A retained scope keeps its captured persistence state after another scope/admission starts. Query live `Runner.persistence_status` after recovery; do not treat the old Execution's `:saved` as an acknowledgement of newer work ([Runner docs](https://github.com/zblanco/runic/blob/d1cd8c6863e89d9742bcd54af44c95097064ce4d/lib/runic/runner.ex#L191)).
- **`Execution.outputs` is an accepted Runnable-result view, not the workflow's logical terminal outputs.** Application-time Join/FanIn coordinator productions are not included; booleans, coordination markers and Fact lists may be. Keep `Workflow.results` / explicit logical-output mapping for the product Run.output ([Execution outputs](https://github.com/zblanco/runic/blob/d1cd8c6863e89d9742bcd54af44c95097064ce4d/lib/workflow/execution.ex#L197)).
- **Large observation lists need benchmarking.** Each `record` computes `length(outcomes)` and appends using `++`; total accumulation is quadratic. A 10,000-item fan-out should qualify observer memory/CPU before exposing full histories. Retention and `forget_execution` are application responsibilities ([record implementation](https://github.com/zblanco/runic/blob/d1cd8c6863e89d9742bcd54af44c95097064ce4d/lib/workflow/execution.ex#L104)).
- **IDs are typed opaque identities.** `Execution.start` accepts `%Runic.Identity{domain: :execution}` and rejects ordinary strings. Do not pass the UUID/string product run ID directly or assume JSON encoders persist structs transparently ([execution identity validation](https://github.com/zblanco/runic/blob/d1cd8c6863e89d9742bcd54af44c95097064ce4d/lib/workflow/execution.ex#L228)).
- **Eager predicate planning bypasses execution policy/deadline handling.** `execute` eagerly plans before deadline conversion; match activation calls `Invokable.execute` directly. The parent review executed a probe confirming that a Rule predicate runs with an already expired `deadline_at`, and a raised predicate escapes `Workflow.execute` with `max_retries: 1` after one attempt. This is a readiness blocker for relying on #43 as the universal safe execution/status interface ([execute planning order](https://github.com/zblanco/runic/blob/d1cd8c6863e89d9742bcd54af44c95097064ce4d/lib/workflow.ex#L3395), [direct invocation](https://github.com/zblanco/runic/blob/d1cd8c6863e89d9742bcd54af44c95097064ce4d/lib/workflow.ex#L4132)).

The parent review's focused PR tests passed **57 tests, 0 failures** across observation, outcomes, deadlines, stable admission and failure suppression; the additional eager-rule probe exposed the above uncovered gap. Local evidence: `/tmp/hermitscale-runic-pr43-focused-tests.log` and `/tmp/hermitscale-runic-pr43-eager-probe.exs`. This shows value and limits, not production readiness.

Readiness gates before selecting the PR-based runtime: fix/test eager Rule exceptions and policy/deadline behavior; test concurrent/repeated inputs and suppression without cross-scope damage; preserve Join/FanIn outputs under observation; prove fresh credentials and immutable revision replay; prove Store errors cannot publish false saved completion; measure 10,000+ outcome accumulation and retention; explicitly document/rebuild historical observations after Worker loss. Once these pass, the PR gives a strong small interface for Run/activation inspection without adding a second engine.
