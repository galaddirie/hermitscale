# Snapshot Checkpoint Policy — Implementation Plan

**Status:** Draft follow-up
**Depends on:** `Runic.Runner.Store.stream/3`, tagged runner workflow snapshots
**Related:** [Checkpointing Implementation Plan](checkpointing-implementation-plan.md), [Lean Replay Implementation Plan](lean-replay-implementation-plan.md), [Full Breadth Runner Scheduling Considerations](full-breadth-runner-scheduling-considerations.md)
**Goal:** Add an explicit, opt-in Worker policy for writing workflow snapshots during checkpointing so snapshot + event-tail resume is useful without changing the event stream source-of-truth model.

---

## Current Context

Runic has two persistence mechanisms with different purposes:

1. **Event checkpoints** are the correctness path.
   The Worker drains `workflow.uncommitted_events` into `Store.append/3` for event-sourced stores. `stream/2` remains the complete event stream.

2. **Workflow snapshots** are an acceleration path.
   The Runner can now consume a tagged workflow snapshot via `load_snapshot/2` and replay `stream/3` with `after_cursor: cursor`. This bounds resume work to the event tail after the snapshot.

The remaining gap is write-side policy: the Worker does not yet decide when to call `save_snapshot/4`. Stores can implement snapshots, but Runic will not automatically create them.

---

## Design Principles

- **Events remain source of truth.** Snapshots are optional acceleration and compaction aids, not the canonical history.
- **Snapshot writing is explicit policy.** Avoid surprising adapters with large blob writes just because they expose `save_snapshot/4`.
- **Keyword-oriented API.** Match existing Runner/Worker ergonomics: clear keyword options passed to `Runic.Runner.start_workflow/4`.
- **Store capabilities are discovered.** Snapshot policy is inert unless the store implements `save_snapshot/4` and `load_snapshot/2`.
- **Append before snapshot.** Save snapshots only after `append/3` succeeds; use the returned cursor as the snapshot boundary.
- **Tagged snapshots only.** Use `Runic.Runner.encode_snapshot/1` so resume never confuses legacy event-log blobs with workflow-state snapshots.

---

## Proposed Public API

Add a Worker option:

```elixir
Runic.Runner.start_workflow(runner, workflow_id, workflow,
  checkpoint_strategy: :every_cycle,
  snapshot_strategy: {:after_events, 1_000}
)
```

### `:snapshot_strategy`

```elixir
:never
:on_complete
:every_checkpoint
{:every_n_checkpoints, pos_integer()}
{:after_events, pos_integer()}
```

Recommended initial default:

```elixir
snapshot_strategy: :never
```

Rationale: this is fully backward compatible and avoids sudden storage growth. Users can opt into snapshots once their store and workload justify it.

### Optional Snapshot Options

Start with one small option map/keyword list rather than many top-level options:

```elixir
snapshot_opts: [
  mode: :full,
  keep: :all
]
```

Initial supported values:

```elixir
mode: :full
keep: :all
```

Reserved follow-up values:

```elixir
mode: :lean
keep: {:latest, 1}
keep: {:latest, n}
```

Do not implement pruning in the first slice unless it is necessary to prove snapshot creation. Snapshot pruning should be a store-adapter concern or an explicit later callback.

---

## Policy Semantics

### `:never`

No Worker-created snapshots.

This remains the safest default. Event-sourced resume still works via full stream replay.

### `:on_complete`

Save a snapshot after the workflow reaches idle/satisfied and final persistence succeeds.

Useful for completed workflow inspection and restart/reporting without adding mid-run snapshot cost.

### `:every_checkpoint`

After each successful event-sourced checkpoint append, save a workflow snapshot at the returned cursor.

Useful only for low-frequency, expensive workflows. Risky for hot workflows because it serializes the whole workflow graph every checkpoint.

### `{:every_n_checkpoints, n}`

Count successful checkpoints and snapshot each nth checkpoint.

This is easy to reason about and mirrors existing `checkpoint_strategy: {:every_n, n}` without overloading it.

### `{:after_events, n}`

Snapshot once `event_cursor - last_snapshot_cursor >= n`.

This best matches snapshot + WAL compaction semantics. It is the preferred production strategy for long-running workflows because it is tied to log growth, not wall time or cycle count.

---

## Worker State Changes

Add fields to `Runic.Runner.Worker`:

```elixir
:snapshot_strategy,
:snapshot_opts,
last_snapshot_cursor: 0,
snapshot_checkpoint_count: 0
```

Initialize from `opts`:

```elixir
snapshot_strategy: Keyword.get(opts, :snapshot_strategy, :never),
snapshot_opts: Keyword.get(opts, :snapshot_opts, [])
```

When resuming from a snapshot, seed `last_snapshot_cursor` from the loaded snapshot cursor. This prevents an immediate duplicate snapshot on first checkpoint after resume.

Implementation note: `Runic.Runner.resume/3` currently passes `resumed: true` and `resolver`. Add a private worker option such as `snapshot_cursor: cursor` when resume used a valid snapshot.

---

## Checkpoint Flow

Current event-sourced checkpoint path:

```elixir
store_mod.append(id, state.uncommitted_events, store_state)
%{state | uncommitted_events: []}
```

Target flow:

```elixir
case store_mod.append(id, state.uncommitted_events, store_state) do
  {:ok, cursor} ->
    state =
      state
      |> mark_checkpoint_persisted(cursor)
      |> maybe_save_workflow_snapshot(cursor)

    %{state | uncommitted_events: []}

  {:error, reason} ->
    # existing error policy / match behavior should remain unchanged initially
end
```

`maybe_save_workflow_snapshot/2` should no-op when:

- `snapshot_strategy == :never`
- the store does not implement snapshot callbacks
- no checkpoint was successfully appended
- policy predicate does not select this cursor/checkpoint

Snapshot payload:

```elixir
snapshot = Runic.Runner.encode_snapshot(state.workflow)
store_mod.save_snapshot(state.id, cursor, snapshot, store_state)
```

Telemetry should wrap snapshot writes separately from append writes:

```elixir
Telemetry.store_span(:save_snapshot, %{workflow_id: id}, fn ->
  store_mod.save_snapshot(id, cursor, snapshot, store_state)
end)
```

---

## Resume Flow Adjustments

The current snapshot-aware resume path should remain:

```text
load_snapshot/2
decode tagged workflow snapshot
stream/3 with after_cursor from cursor
Workflow.from_events(tail_events, base_workflow)
```

Add one extra output from the resume path:

```elixir
{:ok, workflow, resolver, snapshot_cursor}
```

Use `snapshot_cursor = 0` for full-stream resume. Pass it into Worker opts:

```elixir
snapshot_cursor: snapshot_cursor
```

This keeps Worker snapshot counters consistent after snapshot-based recovery.

---

## Testing Plan

### Store Contract Tests

Add tests for the new policy helpers and no-op behavior:

- stores without snapshot callbacks still run with `snapshot_strategy` configured
- `stream/2` remains full stream
- `stream/3` with `after_cursor:` remains tail-only

### Worker Integration Tests

Use a test store that records snapshot writes.

1. `snapshot_strategy: :never`
   - run workflow
   - checkpoint
   - assert `save_snapshot/4` was not called

2. `snapshot_strategy: :every_checkpoint`
   - run workflow
   - assert `save_snapshot/4` was called with cursor returned by `append/3`
   - assert snapshot decodes with `Runic.Runner.decode_snapshot/1`

3. `snapshot_strategy: {:after_events, n}`
   - append fewer than `n` events, no snapshot
   - append enough events, snapshot at current cursor

4. `snapshot_strategy: {:every_n_checkpoints, 2}`
   - first checkpoint no snapshot
   - second checkpoint writes snapshot

5. Resume from Worker-written snapshot
   - run and snapshot a workflow
   - stop
   - resume
   - assert resume uses `stream/3` with `after_cursor:`
   - assert results match full replay

6. Resume seeds `last_snapshot_cursor`
   - resume from cursor N
   - run a small tail below `{:after_events, threshold}`
   - assert no immediate duplicate snapshot

### Full Regression

Run:

```sh
mix format
git diff --check
mix compile
mix test test/runner/worker_test.exs
mix test test/runner/store_ets_test.exs test/runner/store_mnesia_test.exs
mix test
```

---

## Implementation Steps

1. Extend Worker struct/options with `snapshot_strategy`, `snapshot_opts`, `last_snapshot_cursor`, and `snapshot_checkpoint_count`.
2. Add private snapshot strategy predicate helpers.
3. Capture `append/3` returned cursor in `do_checkpoint/1`.
4. Add `maybe_save_workflow_snapshot/2`.
5. Pass `snapshot_cursor` from snapshot-aware resume into Worker opts.
6. Add focused tests using a recording snapshot store.
7. Update `Runic.Runner.Store` docs to describe write-side snapshot policy once implemented.

---

## Open Questions

- Should `snapshot_strategy: :on_complete` run only when the workflow is satisfied, or also when a worker is explicitly stopped with `persist: true`?
- Should built-in ETS and Mnesia implement `save_snapshot/4`, `load_snapshot/2`, and `stream/3` in the same follow-up, or should the first slice stay limited to external stores plus test stores?
- Should snapshot pruning be an adapter responsibility, a future Store callback, or a separate Runner API?
- Should `snapshot_opts: [mode: :lean]` produce a graph with cold `FactRef`s, or should lean snapshots wait until hybrid rehydration has more runtime evidence?

---

## Recommended First Slice

Implement the minimum useful policy:

```elixir
snapshot_strategy: :never | :every_checkpoint | {:after_events, n}
snapshot_opts: [mode: :full]
```

Keep `:never` as the default.

Do not implement pruning or lean snapshot mode yet.

This gives Postgres/SQLite adapters a clear, working compaction path while preserving Runic's event-sourced correctness model and avoiding surprise storage costs.
