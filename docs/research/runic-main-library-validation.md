# Independent validation against Runic main

Validated October 11, 2026 against **main only**, pinned to [6e6373832c00aa9ec5d19faeae945b61e2db50b1](https://github.com/zblanco/runic/commit/6e6373832c00aa9ec5d19faeae945b61e2db50b1). No open-PR code was included. Upstream was not modified to make tests pass.

**The complete upstream suite passes, but three consuming-application concerns reproduce outside that suite:** mapped reducer context raises an arity error, a failed input suppresses another input's retained Join work, and repeated equal legacy inputs execute their mapper again without recording a second reduced occurrence. These observations qualify the upgrade; they do not negate the successful native collection probes.

## Provenance and environment

All execution used the fresh standalone copy `/tmp/hermitscale-runic-main-validation-library`, with its own dependencies and `_build`. The source was copied from the Git checkout of the pinned main commit. A post-run byte comparison of **230 source/test/example files** against the original checkout found **zero differences**. Existing Hermitscale application/vendor/deps/config files were not edited.

- Elixir **1.18.4**, compiled with OTP 27; executing on **OTP 28**, ERTS 16.0.1.
- Runtime `Application.spec(:runic, :vsn)`: **0.1.0-alpha.11**.
- Actual loaded Workflow beam: `/private/tmp/hermitscale-runic-main-validation-library/_build/test/lib/runic/ebin/Elixir.Runic.Workflow.beam`.
- Multigraph dependency locked to **0.16.1-mg.5**.
- Runtime API check: `attach_fan_out/3` absent; `Workflow.execute/3` absent.

The execution record is [runtime-provenance.log](/tmp/hermitscale-runic-main-validation-library/runtime-provenance.log). The source pin is [SOURCE_REVISION](/tmp/hermitscale-runic-main-validation-library/SOURCE_REVISION). Scratch files are reproducibility artifacts for this session, not installed dependencies.

## Complete library suite

After reading `mix help test`, I ran:

```sh
cd /tmp/hermitscale-runic-main-validation-library
mix test --seed 130650 --max-cases 4
```

Exit status **0**. ExUnit's exact summary:

```text
Finished in 15.6 seconds (13.2s async, 2.3s sync)
55 doctests, 1660 tests, 0 failures, 13 skipped
```

Full output: [full-suite.log](/tmp/hermitscale-runic-main-validation-library/full-suite.log).

The fresh dependency build reports **six warnings**, all from `uniq`'s `scoped_uuid.ex`: discarded private `@doc`, four unused private functions, and undefined/private `Uniq.UUID.dump/3`. The log shows **no Runic compiler warnings** on this runtime. This statement concerns this executed build, not every supported Elixir/OTP version.

The **13 skips are already marked in upstream source**, not added or excluded by the validation command:

- Eight [content-addressability tests](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/test/content_addressability_test.exs#L42) covering captured values in rules, accumulators, state machines, maps and reducers, plus corresponding rule/accumulator execution.
- Four [workflow tests](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/test/workflow_test.exs#L899) concerning complex component retrieval, state-machine connections, named composition and reactors.
- One [Runic reactor test](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/test/runic_test.exs#L1152).

## Main-specific behavior probes

The standalone [main_probe.exs](/tmp/hermitscale-runic-main-validation-library/main_probe.exs) uses the exact pinned library and executes real workflows. It contains no branch-specific APIs. Run it with:

```sh
cd /tmp/hermitscale-runic-main-validation-library
MIX_ENV=test mix run --no-compile main_probe.exs
```

Output: [main-probes.log](/tmp/hermitscale-runic-main-validation-library/main-probes.log). The harness reports captured exceptions, so its process exits successfully even when a behavior row below fails. These are explicit experiment results, not additions to the upstream ExUnit test count.

| Behavior | Executed result | Assessment |
| --- | --- | --- |
| Duplicate `[2,2,3]` items, map `x+1`, sum | Reduced output **10**; mapper invoked on **all three occurrences** | Works. Checking the sum alone would not prove mapper multiplicity; this probe counts actual mapper messages. |
| Distinct inputs all map to `:same` | Collected **three `:same` values** | Works; equal output payloads preserve cardinality. |
| Map `x*2`, then ordinary Step `+1`; ordered append over `[3,1,3,2]` | **`[7,3,7,5]`** | Works with native named map/reduce APIs. |
| Raw runtime FanOut/FanIn binding created before two ordinary body Steps | **24** over `[1,2,3,4]` | Works for this linear topology without setting `mapped_paths`. The local fork's attachment constructors are still absent. |
| Ordinary named Step within map reads `context(:factor)` | **60**, factor 10 | Works with context scoped to that ordinary Step. |
| Native map lambda reads `context(:factor)` with global context | **60**, factor 10 | Works. This probe supplies `_global`; it does not establish map-component-only context propagation. |
| Mapped reducer reads `context(:weight)` | **`BadArityError`: reducer/3 called with two arguments `(1,0)`** | **Fails.** Reproduces the upgrade concern. |
| Aggregate Join of reduced map sum and independent source count | **`{10,3}`** | Works for the tested topology. |
| Eager event replay after map body, before FanIn completion, then resume | **10** | Works within the current main revision. |
| A `:bad` root fails while `:good` retains work for the same Join | **No `:good` Join output** | **Fails root isolation.** Pending work from the healthy input is suppressed by the failed input. |
| Two identical legacy inputs on one accumulated workflow | Mapper receives **three items on each call**; graph exposes **one reduced production `[10]`** | **Occurrence boundary is inadequate for consumers expecting two independent executions.** |
| Map/reduce over `[]`, initial sum 0 | **No reduced output** | Existing native semantics; does not return the initial accumulator. |

The duplicate-count probe emits mailbox messages from the synchronous mapper and drains them afterward. It does not depend on timing or sleeps. The failure-isolation probe deliberately holds one bad-input Join arrival and one good-input arrival before accepting the failed runnable, then drains the remaining workflow.

## Source explanations for the reproduced concerns

Mapped reducer context is assembled during prepare, but [FanIn's coordinator](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/fan_in.ex#L67) invokes a helper that [calls reducer/2](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/fan_in.ex#L126). The `context/1` macro emits reducer/3. The exact executed reproduction is:

```elixir
Workflow.new()
|> Workflow.add(Runic.map(fn x -> x end, name: :nums))
|> Workflow.add(
  Runic.reduce(0, fn x, acc -> acc + x * context(:weight) end, name: :weighted),
  to: :nums
)
|> Workflow.put_run_context(%{weighted: %{weight: 10}})
|> Workflow.react_until_satisfied([1, 2, 3])
```

Failed-runnable handling calls [global downstream suppression](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow.ex#L4606); [the suppression implementation](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow.ex#L4624) relabels pending downstream edges without comparing root ancestry. The two-root result matches that source behavior.

For repeated legacy inputs, default [Fact identity construction](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/fact.ex#L37) does not independently allocate a new command occurrence. FanIn completion is [keyed by source Fact identity](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/fan_in.ex#L43). Consumers can supply explicit distinct root Fact identities or isolate executions in separate workflows, but the validation here establishes the behavior of repeated unwrapped legacy values, not a completed application adaptation.

Conversely, the successful runtime region corresponds to upstream's [ordinary single-output collection discovery](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/single_output.ex#L194), and duplicate cardinality corresponds to [indexed fan-out ancestry](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/invokable.ex#L939). Those are verified native mechanisms suitable for removing portions of the fork after integration changes.

## What this validation establishes

Current main builds and passes its complete existing library suite under Hermitscale's local Elixir runtime. Basic native collection composition, item multiplicity, ordered reduction, an aggregate Join and same-version replay all execute successfully. The identified consumer edge cases remain observable on main.

This library validation does not prove the unchanged Hermitscale compiler can use main, that its persistence adapter accepts new identity/event schemas, that old patched history can replay under main, or that arbitrary branching/nesting/concurrent batches preserve desired semantics. Those require application-level adaptation and targeted tests. No recommendation here depends on unmerged code.

## Follow-up application experiment

The parent subsequently completed an isolated compatibility adaptation using the same unmodified main commit. Its full application `mix precommit` passed **300 tests, zero failures** after three application-file changes, including native collection composition, expression binding compatibility, named Reduce output connections, and runtime-only replay against the compiled definition. This does not resolve the standalone concerns above. See the [application validation and reviewable patch](runic-main-application-validation.md). Permanent copies of this library's logs are [full suite](runic-main-validation-evidence/library-full-suite.log) and [main probes](runic-main-validation-evidence/library-probes.log).
