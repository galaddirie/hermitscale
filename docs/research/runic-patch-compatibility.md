# Runic patch compatibility assessment

Assessment date: October 11, 2026. This is a source audit plus isolated execution probes, not an application refactor.

**Verdict:** current upstream independently solves duplicate-item identity and supports the runtime-built linear collection topology that motivated much of our fork. It does **not** contain our builder/query/trace APIs or our graph-only fan-in implementation. Native mapped reduction with `context/1` still fails, whereas our patch works. Open PR #43 adds useful execution occurrence and outcome contracts and fixes cross-input failure suppression through its #42 dependency; it does not redesign collection ownership.

## Provenance and exact patch inventory

The application declares `{:runic, path: "vendor/runic"}` in [mix.exs](/Users/galdirie/code/hermitscale/mix.exs:72). Vendored `mix.exs` reports `0.1.0-alpha.8`.

I hashed every retained vendored file with `git hash-object` and compared its blob against every upstream revision reachable in the fetched repository. **148 of 158 retained files match the May 29 source tree byte-for-byte.** The source baseline is [75ed26f147c97fe01269498526f491f9bb98fa66](https://github.com/zblanco/runic/commit/75ed26f147c97fe01269498526f491f9bb98fa66), equivalently its parent [e0561f6795d1eeba7378a6486329ecb18732b8f0](https://github.com/zblanco/runic/commit/e0561f6795d1eeba7378a6486329ecb18732b8f0): those complete upstream trees have no diff. Later docs-only revisions match the same retained blobs, so blobs alone cannot name a unique checkout commit. Hermitscale's July 5 import commit `796788e46e6c8261e4ce0693e36f065a01037d83` predates those later revisions and supports the May 29 baseline.

Against that baseline, these are the complete differences in retained code/tests:

| File | Change |
| --- | --- |
| `lib/runic.ex` | Single-function map body inherits map name; internal fan-out gets `.fan_out` suffix. |
| `lib/workflow.ex` | Runtime region attachment, `regions/1`, `scope_of/2`, `trace/1,2`; remove bespoke collection-event applicators and collection side-table initialization. |
| `lib/workflow/events.ex` | Remove three bespoke collection event types from the public event union/delegates. |
| `lib/workflow/invokable.ex` | Remove Step collection bookkeeping; index-aware scattered Fact identity/metadata; ordinary `FactProduced` collection events; unified FanIn invoke/prepare/execute path. |
| `lib/workflow/component.ex` | Map registration collision avoidance; Reduce bindings no longer snapshot `mapped_paths`; adjust merged mapped state. |
| `lib/workflow/fan_out.ex` | Runtime constructor and `Runic.Component` implementation. |
| `lib/workflow/fan_in.ex` | Runtime constructor and `Runic.Component` implementation; replace side-table coordinator with graph/ancestry completion and context-aware reduction. |
| `test/parallel_workflow_test.exs` | Assert scattered facts survive merge instead of asserting `mapped_paths`. |
| `test/workflow/event_sourced_test.exs` | Assert ordinary collection `FactProduced` events instead of bespoke event types. |
| `test/workflow/region_test.exs` | New runtime-region, ordering, duplicate-item, replay and trace coverage. |

The fork also **deletes** `lib/workflow/events/fan_out_fact_emitted.ex`, `fan_in_completed.ex`, and `map_reduce_tracked.ex`. Other removed paths are docs/assets/benchmarks. The retained Runner worker and `test/workflow/fan_out_join_dispatch_test.exs` match upstream baseline exactly: the task-crash/failing-Join fixes described in that test are already upstream code in the source we vendored, **not additional Hermitscale patches**.

Historical rationale survives in Git: `git show 796788e:vendor/runic/.docs/map-reduce-region-redesign.md`. It identifies runtime JSON graph compilation, macro AST limitations, order-sensitive `mapped_paths`, mutated `Map.pipeline` metadata drift, and leaf/name coupling. The implementation was already present when the vendor import landed; the next app commit `0c120c6` switches the compiler to explicit `prepare → fan_out → mapper → body → fan_in` construction.

## Patch-by-patch verdict at current main

Current main is pinned to [6e6373832c00aa9ec5d19faeae945b61e2db50b1](https://github.com/zblanco/runic/commit/6e6373832c00aa9ec5d19faeae945b61e2db50b1), whose package version is `0.1.0-alpha.11`.

| Local requirement | Verdict | Evidence and implications |
| --- | --- | --- |
| Distinct equal fan-out elements | **Solved independently upstream** | Upstream fan-out records `FactAncestry.output_index`; identity includes causal coordinates. Its [identity test](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/test/identity_test.exs#L145) asserts equal payloads get distinct occurrences. Executed mapper-count probe below confirms this. |
| Runtime-built multi-step linear map body, binding before body construction | **Solved for tested topology; API migration required** | [SingleOutput.collection_sources](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/single_output.ex#L194) discovers an ordinary leaf's direct FanIn connection and follows `FanOut.origin`, without requiring snapshotted `mapped_paths`. [Official collection tests](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/test/single_output_collection_test.exs#L9) cover custom topology, an intervening ordinary node and fallback values. Our direct runtime primitive probe completes on current upstream and fails silently on the original baseline. |
| `FanOut.new/1`, `FanIn.new/1`, `attach_fan_out/3`, `attach_fan_in/4` | **Not adopted** | Our [constructors](/Users/galdirie/code/hermitscale/vendor/runic/lib/workflow/fan_out.ex:15) and [attachment APIs](/Users/galdirie/code/hermitscale/vendor/runic/lib/workflow.ex:2078) are absent upstream. Compiler calls them at [compiler.ex:107](/Users/galdirie/code/hermitscale/lib/hermitscale/workflows/compiler.ex:107) and [compiler.ex:137](/Users/galdirie/code/hermitscale/lib/hermitscale/workflows/compiler.ex:137). Replace this integration, not merely the dependency. Raw structs/edges work in a narrow probe; a maintained Component boundary is preferable to reimplementing protocol logic in app code. |
| Eliminate side tables and bespoke collection events | **Semantic difference remains** | [Upstream FanIn](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/fan_in.ex#L35) still coordinates from `wf.mapped` and emits `FanInCompleted`; fan-out emits `FanOutFactEmitted`; ordinary collection nodes emit `MapReduceTracked`. Our [coordinator](/Users/galdirie/code/hermitscale/vendor/runic/lib/workflow/fan_in.ex:65) derives completion from facts/ancestry and emits `FactProduced :reduced`. Successful native replay is evidence of a usable alternative, not evidence our event design was adopted. |
| Deterministic order; stale prepared FanIn completes after later arrivals | **Native implementation works in tested cases** | Both reduce in fan-out emission order. Upstream [compact dispatch tests](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/test/workflow/compact_dispatch_test.exs#L132) verify preparation before the last arrival and duplicate application. A constant-size coordination context looks up current state during finalize. |
| Mapped reducer reads `context/1` | **Unresolved upstream; functional regression if patch removed** | The macro generates reducer/3. [Coordinator line 67](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/fan_in.ex#L67) calls a helper that [invokes reducer/2](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/fan_in.ex#L126), ignoring prepared run/meta context. Our [coordinator](/Users/galdirie/code/hermitscale/vendor/runic/lib/workflow/fan_in.ex:117) merges and passes context. Executed comparison: vendor 60; main and PR43 `BadArityError`. Ordinary mapped Steps using `context/1` work. |
| Region/scope queries and per-node item trace | **Not adopted** | Our [queries](/Users/galdirie/code/hermitscale/vendor/runic/lib/workflow.ex:2114) and [trace](/Users/galdirie/code/hermitscale/vendor/runic/lib/workflow.ex:2615) have no exact native replacements in main. PR43 execution outcomes are complementary and omit graph productions created during coordination. Preserve product tracing as an application adapter or agree an upstream contract. |
| Single-function map naming and registry collision avoidance | **Local convention remains** | Our [macro](/Users/galdirie/code/hermitscale/vendor/runic/lib/runic.ex:4355) assigns names to internal nodes for trace rows. Upstream still uses its component/subcomponent naming. Application node identity should map to Runic component names explicitly rather than depend on fork naming. |
| Empty batch produces initial accumulator | **Neither implementation does this** | Native map/reduce on `[]` produces no reduced output in baseline, vendor, main or PR43. The local coordinator requires `expected > 0`; upstream requires a nonempty expected set. This is an existing semantic limit, not a newly introduced regression. |

## Executed probes

All runs used separate `/tmp/hermitscale-runic-patch-probes-20261011/{baseline,vendor,upstream,pr43}` projects, copied dependencies, and isolated builds. No application, vendored source, dependency directory or config in the working repository was changed. Runtime: Elixir 1.18.4, OTP 28. Upstream uses Multigraph `0.16.1-mg.5`; baseline/vendor use `mg.4` from their lockfiles.

The common script is `/tmp/hermitscale-runic-patch-probes-20261011/probe.exs`; logs are `baseline-probes.log`, `vendor-probes.log`, `upstream-probes.log`, and `pr43-probes.log` in that directory. These are disposable reproduction artifacts. Results:

| Probe | Original baseline | Our vendor | Current main | PR43 |
| --- | --- | --- | --- | --- |
| Map `x+1`, reduce sum, input `[2,2,3]` | 10 | 10 | 10 | 10 |
| **Actual mapper invocations for that input** | **2: `[2,3]`** | **3: `[2,2,3]`** | **3: `[2,2,3]`** | **3: `[2,2,3]`** |
| Two-step map `x*2`, then `+1`, ordered append over `[3,1,3,2]` | `[7,3,7,5]` | same | same | same |
| Different items all map to `:same` | 3 collected values | same | same | same |
| Bind raw runtime FanOut/FanIn before adding two body Steps; `[1,2,3,4]` | no reduction | 24 | 24 | 24 |
| Native map context and separately named Step context | 60 | 60 | 60 | 60 |
| Native mapped reducer `acc + x * context(:weight)` with per-node weight 10 | `BadArityError` | 60 | `BadArityError` | `BadArityError` |
| Join completed map sum with independent source count | `{10,3}` | same | same | same |
| Replay emitting workflow after body ran, before FanIn; then resume | 10 | 10 | 10 | 10 |
| Failed root while another root retains Join work | loses good-root result | loses good-root result | loses good-root result | good-root Join completes |
| Empty collection | no reduction | same | same | same |

**The sum alone hides the old duplicate-item bug.** The original baseline reduced a repeated expected entry twice while executing the mapper only once for equal item occurrences. The mailbox-count probe uses `send(self(), ...)` inside the synchronous mapper and drains its messages afterward, directly measuring attempt multiplicity. This matters for network calls and other effects.

A second occurrence probe fed identical `[2,2,3]` into the same accumulated workflow twice through legacy `react_until_satisfied`. Vendor, main and PR43 invoked three mappers **on each input**, but their graph exposed only **one** reduced production, `[10]`. Under PR43's new `Workflow.execute/3`, two executions instead received distinct input Fact IDs and produced two graph reductions, `[10,10]`. This verifies the value of execution-level occurrence identity. It is **not** a general concurrent batch-ownership test.

Existing library test runs:

- Vendor region/event-sourcing/parallel-workflow files: **86 tests, 0 failures**.
- Main event-sourcing/parallel-workflow/identity files: **87 tests, 0 failures**.
- Main compact-dispatch/custom-single-output-collection files: **16 tests, 0 failures**.
- PR43 failure-suppression/execution-outcome files: **12 tests, 0 failures**.

## Open PR43 and its #42 dependency

PR43 is open and pinned to [d1cd8c6863e89d9742bcd54af44c95097064ce4d](https://github.com/zblanco/runic/commit/d1cd8c6863e89d9742bcd54af44c95097064ce4d). [The PR description](https://github.com/zblanco/runic/pull/43) explicitly includes #42 and excludes batch ownership. Comparing its tree to pinned main shows **no diff** in `fan_in.ex`, `fan_out.ex`, `invokable.ex`, `single_output.ex`, or `fact.ex`; our mapped-reducer context failure persists.

Its #42 dependency changes failure suppression to compare root ancestors and records `ActivationSuppressed` events for replay. The [source](https://github.com/zblanco/runic/blob/d1cd8c6863e89d9742bcd54af44c95097064ce4d/lib/workflow.ex#L4837) and [tests](https://github.com/zblanco/runic/blob/d1cd8c6863e89d9742bcd54af44c95097064ce4d/test/workflow/failure_suppression_test.exs#L14) match our executed two-root Join result. It still uses global suppression for explicit skipped activations/public `skip_downstream_subgraph/2`, and item siblings in one collection share a root. Do not interpret root isolation as per-item failure-policy or batch-ownership isolation.

PR43 derives [input command/root Fact occurrence identities from execution identity](https://github.com/zblanco/runic/blob/d1cd8c6863e89d9742bcd54af44c95097064ce4d/lib/workflow/execution.ex#L88), which explains the repeated-input result above. Observations stay process-local and one observed execution may progress per Worker; graph Join/reduce productions remain separate from accepted Runnable outcomes. These are useful product contracts, but durable run reconstruction still needs the existing Store/event boundary.

## Interpretation and limits

The verified evidence supports removing substantial vendor behavior **after adapting our compiler/component boundary**, then using native identity, ordinary single-output collection tracking and scheduling. It does not support a dependency-only replacement or deleting every patch indiscriminately. Keep mapped reducer context out of the native coordinator path until fixed/tested; retain required inspection capabilities outside the fork; explicitly define empty-collection behavior and run occurrence identity.

Our probes establish linear regions, duplicate items, ordered folds, an aggregate Join, and same-version eager event replay. They do not establish nested-region ownership, arbitrary branch filtering, shared-parent per-item Joins, concurrent collection scopes, large-batch performance, event portability between runtimes, or exactly-once external effects. Neither a green library suite nor a quiescent workflow guarantees a required reduction exists; assert product outputs.

Finally, [upstream's migration guidance](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/CHANGELOG.md#L13) says there is no general old-hash-to-new-hash upcaster and retained logs must stay with their original runtime or receive an explicit migration. The native replay probes rebuild and replay **within each revision**; they do not validate replay of Hermitscale's patched event schema onto current upstream.
