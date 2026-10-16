# Workspaces and Runs Design

Status: Proposed  
Date: October 16, 2026  
Supersedes: the Jido/Harness design reverted in `22f367e`

Hermitscale lets users provision persistent cloud compute that their workflows and
agents can drive. A workspace is one [Fly.io Sprite](https://docs.fly.io/sprites): a
persistent Linux microVM that sleeps when idle, wakes on demand, and keeps its disk.
Hermitscale exposes a small set of generic primitives over it. Everything users build
(coding agents, hosted services, long research sessions, generated artifacts) is
composed from these primitives by the user. None of it is special-cased in our code.

## Principles

- **Sprites does the hard parts.** Persistence, sleep/wake, detached commands, keep-awake
  holds, service restarts, checkpoints, and URLs are platform features. We don't
  reimplement them.
- **Generic primitives only.** No module, schema, or branch knows about a specific
  tool, agent CLI, or use case. A run is a command, and a service is a command with a port.
- **Postgres stores identity and status, not a second copy of the machine.** The Sprite's
  disk is the source of truth for files, tool state, and full run output.
- **No agent framework, no on-Sprite worker, no custom protocol.** We use the `sprites` SDK,
  Postgres, Oban, and PubSub.

## What Sprites already provides

| Need | Sprites feature |
| --- | --- |
| Long-lived machine that costs nothing idle | Persistent ext4 disk; warm wake 100–500ms, cold wake 1–2s |
| Commands that outlive our connection | Exec sessions continue after disconnect; list, attach, kill |
| Keep awake while work runs | Tasks API (`/.sprite/api.sock`), heartbeat that expires on crash |
| Processes that come back after sleep | Services restart on cold boot; the HTTP service auto-starts on request |
| Save points | Copy-on-write checkpoints with comments; last five mounted read-only |
| Serve HTTP | Per-Sprite URL with `sprite` (private) or `public` auth |
| Egress control and brokered credentials | Network policy; Connectors |

## Primitives

All primitives live in `Hermitscale.Workspaces`, take a verified `scope` first, and act
on an organization-owned workspace.

| Primitive | Behavior | State |
| --- | --- | --- |
| Create / delete workspace | Provision or destroy the Sprite. There is no explicit wake: any use wakes it. | Exists |
| `execute` | Short command; returns stdout, stderr, and exit code. | Exists |
| `start_run` / `cancel_run` / `get_run` / `list_runs` | Long command that survives disconnects and Phoenix restarts, with streamed output. | **New** |
| Checkpoint / restore / list | Pass-through to Sprite checkpoints. | Exists |
| Services and URL settings | Define a service (optionally the HTTP one) and set URL auth. | Exists |
| Files | Read, write, list, delete. | Exists |

### Runs

A run is an arbitrary command started detached inside the workspace. It is the only new
concept.

**On the Sprite.** `start_run` executes a small wrapper script (`hs-run`, installed into
the workspace on first use) with a run ID and the user's command. The wrapper:

1. Creates `~/.hermitscale/runs/<id>/`.
2. Upserts a Sprite task `run-<id>` with a 5-minute expiry and refreshes it every minute.
3. Runs the command, appending combined stdout and stderr to `output.log`.
4. Writes the exit status to `exit_code`, then deletes the task.

The wrapper is about 40 lines of shell. If it crashes, the task expires and the Sprite
sleeps. The files on disk are the run's journal.

**In Postgres.** A `workspace_runs` table holds: workspace, command, args, env keys
(never values), working directory, Sprite exec session ID, status
(`running | exited | cancelled | lost`), exit code, output offset, a bounded output
tail, and timestamps.

**Watching.** One unique Oban job per active run tails `output.log` from the stored
offset, broadcasts chunks over PubSub, and periodically saves the offset and output tail.
Once `exit_code` exists, it records the result and stops. If the node restarts, Oban
reruns the job, which resumes from the saved offset. Nothing is replayed or rerun.

**Cancelling.** Kill the exec session. The wrapper traps the signal, records the exit
status, and releases its task.

**Lost runs.** A run is `lost` when its session is gone and no `exit_code` was written
(for example, the Sprite was restored to an earlier checkpoint). Any output already on
the Sprite's disk is kept.

**History.** Finished runs are served from Postgres without waking the Sprite. The full
log stays on the Sprite's disk for anyone who needs it.

Runs have no concurrency limit. A workspace can have several at once, and coordinating
them is up to the user.

## Composition (examples, not implementation)

These show what users can build from the primitives. They are not modules, schemas,
or code paths.

- **Coding agent:** a run of the agent's CLI in headless mode. The CLI's own session
  history lives on the persistent disk, so a follow-up is another run with its resume flag.
- **Hosted web app or service:** an HTTP service plus URL settings. The URL wakes the
  Sprite and the service starts on demand.
- **Long-lived interactive session:** a service that renders on request. It can sit
  asleep for months and answer within normal request latency.
- **Risky change:** checkpoint, then run; restore if it fails.

## Explicit non-goals for this pass

- Workflow nodes and triggers (a later pass will add "start run" and "run finished").
- Agent frameworks (Jido, Harness, ACP), on-Sprite workers, and custom protocols.
- Hermitscale-managed credentials. Callers pass env values to a run, and we never
  persist them. Sprites Connectors are the intended later path.
- Approvals, deployment records, usage metering, retention policies, and backups.
- Browser UI and a private-URL proxy. These depend on browser auth, which doesn't exist yet.

## Trade-offs

| Given up | Why it's acceptable |
| --- | --- |
| Fencing against a stale writer after a crash | Sessions and `exit_code` are authoritative; users can cancel stray runs. |
| Restore that preserves newer data | Restore rewinds the whole disk, which is the documented Sprite behavior. Users choose where to keep data. |
| Durable per-event history in Postgres | Postgres keeps a bounded tail; the full log is on the Sprite. |
| Exactly-once semantics for side effects | Runs are user commands; we guarantee only that we never start one twice. |

## First slice

Goal: start a long command, disconnect, restart Phoenix, and still see it finish with
its output and exit code. Then start a second run in the same workspace and confirm
files from the first are still there after the Sprite slept.

| Piece | Rough size |
| --- | --- |
| Migration and `Run` schema | 60 lines |
| Run functions in `Workspaces` | 150 lines |
| `hs-run` wrapper (`priv/workspaces/hs-run`) | 40 lines |
| Oban watcher | 120 lines |
| Tests (fake client plus wrapper behavior) | ~300 lines |

About 400 lines of production code. If any piece grows past a few hundred lines, stop
and revisit the design.
