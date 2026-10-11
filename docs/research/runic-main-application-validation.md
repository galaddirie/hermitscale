# Hermitscale validation against Runic main

Validated October 11, 2026 against **[main at 6e6373832c00aa9ec5d19faeae945b61e2db50b1](https://github.com/zblanco/runic/commit/6e6373832c00aa9ec5d19faeae945b61e2db50b1)**. Remote `refs/heads/main` was checked again after the experiments and still pointed to this commit. **No PR #43 code was included.** Main reports `0.1.0-alpha.11`, but the September release and October main are different source targets.

**A working application compatibility prototype now exists: the full Hermitscale `mix precommit` passes on unmodified Runic main, with 300 tests and zero failures.** This changes the earlier assessment from an unproven compiler proposal to an executable route for removing our vendor patches from the currently tested feature set. It remains an application adaptation, not a drop-in dependency replacement or a migration of existing histories.

## Applied upgrade

The real workspace now uses `{:runic, github: "zblanco/runic", branch: "main"}`,
locked to the same validated commit, and the patched `vendor/runic` directory has
been removed. The application requires Elixir 1.18. Native Map/Reduce composition,
named Reduce output connections and deterministic compiler parameter bindings
replace the previous fan-out/fan-in patch calls. Runtime-only parameter values are
rejected before encoding.

**Final real-workspace `MIX_TEST_PARTITION=runic_upgrade mix precommit`: 311 tests,
0 failures, exit 0** (seed 601445, 5.6 seconds). Evidence:
[upgrade precommit](runic-main-validation-evidence/upgrade-precommit.log) and
[upgrade runtime provenance](runic-main-validation-evidence/upgrade-provenance.log).
The Runic dependency checkout is clean at the locked GitHub revision. PR #43 is
not included.

Regression coverage proves duplicate collection occurrences retain cardinality,
second-iteration output and total count survive reduction and serialized event
replay, empty collections have zero iterations, and accepted mapper effects are
not repeated during partial replay. This preserves native Fact-level inspection;
`Run.output` continues to hold final outputs, and no new UI inspection API was
introduced.

Recovery now persists an application `DefinitionRecorded` event before Runic's
initial build events. Its fingerprint covers compiled node identities,
connections, edge properties, named components, scheduler policies and authored
expression context, before runtime credentials are injected. Replay requires a
matching record and retains incremental runtime/lifecycle events while excluding
build-source evaluation. An independent review reproduced a topology-only rewire
that retained all component identities; both partial replay and persisted-run
regressions now reject that change. Unchanged recompilation resumes successfully.
Existing vendor histories and histories without this new definition record are
not migrated or resumed automatically. Callback and expression-plan versions
must remain compatible; this upgrade does not introduce immutable graph revisions.

The full code-quality comparison retains existing findings without a new
complexity finding in this upgrade. Security dependency auditing remains
incomplete: the installed `mix deps.audit` tool fails because YamlElixir is missing,
Sobelow is unavailable, and Hex reports the pre-existing Plug 1.20.1 version as
retired. Plug was not changed by this upgrade.

The remaining sections record the earlier isolated prototype experiments; their
workspace-preservation statements describe that earlier validation, before the
user authorized the applied upgrade.

## Historical prototype checks

| Check | Result |
|---|---|
| Independent clean main library, full existing suite | **55 doctests, 1,660 tests, 0 failures, 13 existing skips** |
| Unchanged Hermitscale compiler with fresh main | **30 targeted tests, 22 failures** |
| Native Map/Reduce compiler adaptation alone | **30 targeted tests, 20 failures**, revealing the expression-identity incompatibility |
| Native composition plus expression binding adapter | **30 targeted tests, 0 failures** |
| First full application `mix precommit` with those two adaptations | **298 tests, 2 failures**: downstream Step after Reduce and stored-run resume |
| Final compatibility prototype, full `mix precommit` | **300 tests, 0 failures**; original 298 plus two additional application checks |
| Byte comparison of the application copy's Runic `lib/` against pinned main | **114 files checked, zero differences** |
| Runtime API provenance | Loaded alpha.11 Workflow beam from the fresh application copy; PR #43 `execute/3` absent |

The final command was:

```sh
cd /tmp/hermitscale-runic-main-validation-app
MIX_TEST_PARTITION=runic_main_validation mix precommit
```

It exited **0** and ran the project's compile-with-warnings-as-errors, unused dependency unlock, formatting, and full test aliases. Exact test summary: `300 tests, 0 failures`, seed `213279`, 5.1 seconds. Two warning logs come from deliberately failing trigger fixtures; they do not indicate compilation or test failures.

The application snapshot included the user's current work in progress, excluded `.env`, and used a separate test partition. Main had a fresh dependency build, including Multigraph `0.16.1-mg.5`. Execution used Elixir 1.18.4 on OTP 28. The original vendor, dependency declarations, lockfile, config, application/test source, and unrelated edits in the real workspace were not changed by this validation.

Permanent evidence: [application precommit](runic-main-validation-evidence/application-precommit.log), [runtime provenance](runic-main-validation-evidence/application-provenance.log), [full library suite](runic-main-validation-evidence/library-full-suite.log), and [standalone main probes](runic-main-validation-evidence/library-probes.log). The independent [library validation](runic-main-library-validation.md) documents its environment, existing skips, source comparison and probe methodology.

## What the application needed

The [reviewable experiment patch](runic-main-compatibility-experiment.patch) changes **three application files and adds two tests**. This is the historical prototype patch; the real application now contains the expanded implementation described above. At prototype validation time, `git apply --check` succeeded against the working tree; the patch assumes the pinned main dependency and its resolved dependencies, which are deliberately not bundled into this application patch.

1. **Compile collections with public components.** The node builder returns `Runic.map([mapper], name: helper_name)` and a complete `Runic.reduce(..., map: helper_name)` component. The compiler uses `Workflow.add/3` for the region and body. It removes application calls to patched `FanOut.new`, `attach_fan_out`, `attach_fan_in`, and explicit mapper registration. Logical mapper and reducer names remain available for scheduler policies and terminal output queries.
2. **Make captured expression plans acceptable to identity hashing.** Main rejects our captured `%Solid.Template{}` values with `Runic.Identity.CanonicalError`. The experiment binds deterministic compiler-created parameter binaries and decodes them with `binary_to_term(..., [:safe])` inside the node. This is a compatibility proof, not a finalized portable expression format: it adds decoding work per activation and couples the bytes to the Elixir/parser representation. A production design should choose a versioned semantic projection or a portable source plan, and benchmark it. It does not accept externally supplied serialized terms.
3. **Use a named connection after a Reduce.** On main, legacy single-parent `Workflow.add(step, to: reduce_name)` connects the Step to the Reduce wrapper, while the produced value belongs to its FanIn. The final debug Step never runs. The independent agent reproduced this with graph inspection and then proved that `connections: [[from: {reduce_name, :result}, to: :in]]` delivers `[20,40,60]` to that Step. The prototype uses this public connection path for a single Reduce parent. Multi-parent reduced-output joins also pass the existing fixtures.
4. **Replay runtime events against the compiled definition.** A native Map imports an internal build log even when the outer application addition uses `log: false`. `from_events(events, base_workflow)` still evaluates those build sources before discarding rebuilt structure, and the imported FanOut source raised a `CompileError` in this application. The prototype removes `ComponentAdded` records before this call, retaining runtime and runnable lifecycle records. This restores the stored-run resume test using the application's already compiled base. It is valid for the current fixed-graph recovery approach; it is unsuitable for silently discarding meaningful dynamically added structure in a future design.

These address the observed integration failures without changing Runic itself. Native Map still creates engine-owned FanOut/FanIn machinery; the application no longer constructs or patches it.

Upstream source supporting these observations: [Map/Reduce/Step composition](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/component.ex), [named connection output resolution and event reconstruction](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow.ex), and [canonical identity encoding](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/identity/canonical.ex).

## What the passing suite covers

The existing application tests cover per-item expressions, `$node` references entering a map, ambient `$env` in maps and reducers, linear body chains, ordered concatenation, empty input's existing no-result semantics, reduced output into a Join, terminal output keyed by logical node name, supervised Runner execution, credential context, Postgres event storage, and stored-run resume.

The two added tests prove **three equal mapped outputs from `[2,2,3]` reduce to 9**, and **a partially executed application map region survives binary event round-trip and completes to 60 against its compiled base**. The latter enables native incremental event emission, checks that the partial workflow has pending work and no reduced result, then replays and drains it. It does not merely stop and resume an already complete run. Separate standalone library probes also count actual mapper invocations to establish duplicate input multiplicity.

## Remaining main-only issues and limits

The full application pass does **not** make all main behaviors correct. Independent main-only probes still reproduce:

- A mapped reducer using `context(:weight)` raises **BadArityError**. Hermitscale's current reducer captures graph ambient data and avoids this path; the existing ambient reducer test passes in the prototype. Deeper runtime-context adoption inside mapped reducers still needs a fix or deliberate application design.
- One failing input can suppress another input's retained Join work on a shared workflow.
- Two identical legacy input commands run their mapper again but expose only one reduced occurrence in accumulated graph output. Explicit input occurrence IDs or separate workflow instances need application qualification. PR #43's execution path was not used to achieve this application pass.

No old patched histories were replayed on main. No arbitrary nested/branched or concurrent collection batches, production workloads, provider side-effect guarantees, or cross-deployment callback recovery were qualified. The current Validator continues rejecting unsupported map-region shapes. The resume adapter still depends on the current graph definition; immutable graph and callback versions remain required before migrating durable runs. Standalone reconstruction from the native collection build log remains an observed limitation, rather than a guarantee rescued by this prototype.

**Updated recommendation:** proceed with a narrowly scoped main-pinned compatibility refactor based on this proven path. The current tested Hermitscale features can run without vendor patches. Gate rollout and patch retirement on durable-run versioning/history handling and the consumer behaviors the product actually needs; qualify PR #43 separately when evaluating its proposed observation APIs.

## Follow-up: iteration metadata survives native collections

A further executable probe against the same unmodified main confirms that iteration outputs and counts remain recoverable. Runic's [FactAncestry](https://github.com/zblanco/runic/blob/6e6373832c00aa9ec5d19faeae945b61e2db50b1/lib/workflow/fact_ancestry.ex) records parent/producer coordinates and a zero-based output index. FanOut records each emitted item with its own index; ordinary body Step outputs link back to that item through their parent facts. A body Step's own `output_index` defaults to zero, so querying iteration requires following ancestry to the relevant FanOut rather than reading the final output's index directly.

Executed native pipeline: input `[3,1,3,2]`, map body `double → increment`, followed by ordered collect. The probe recovered outputs `[7,3,7,5]`, the **second iteration's output `3`**, and **total count `4`**. All four item occurrence IDs were distinct despite the duplicate input/output values. The same rows and total survived binary incremental-event round-trip and replay against a fresh authored base, after reduction completion and expected-count coordinator-table cleanup. Before body execution completed it recovered planned count `4` and completed body-output count `0`; empty input yielded count `0`.

The probe uses `Workflow.facts/1`, `Workflow.productions/2`, and component lookup. It does not require a Runic patch or the fork's `trace/2`. These APIs retain full Fact metadata; `raw_productions` alone returns values and does not provide stable iteration ordering. A Hermitscale query projection can expose `{run, map, source_batch, iteration, node}` lookups and separate planned/completed/failed counts. The executable helper assumes one batch; production queries must select a batch explicitly and use the chosen FanOut for nested regions, whose semantics remain outside this validation.

The application's persisted terminal `Run.output` is not this trace. Intermediate metadata must be queried from the retained Workflow or replayed/projected from its event log. Full replay was exercised here; obtaining payloads after lean replay additionally requires fact hydration. No app query API was implemented by this follow-up.

Evidence: [probe source](runic-main-validation-evidence/iteration-metadata-probe.exs) and [executed results](runic-main-validation-evidence/iteration-metadata.log). Reproduce with `MIX_ENV=test mix run --no-compile --no-start /Users/galdirie/code/hermitscale/docs/research/runic-main-validation-evidence/iteration-metadata-probe.exs` from the clean main library copy with its dependencies and test build available.
