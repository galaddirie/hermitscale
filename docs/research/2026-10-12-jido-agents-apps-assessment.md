# Jido assessment for Hermitscale Agents and Apps

Date: October 12, 2026. Scope: the proposed [Agents and Apps design](../agent-apps-design.md), not an implementation or dependency change. Research used official documentation, Context7 for discovery, and directly fetched official source. Runtime conclusions below were checked against **Jido v2.4.0**; mutable ecosystem sources need separate version qualification.

Status: Historical assessment. The adoption recommendation below is superseded by the [current platform design](../agent-apps-design.md) and [runtime simplification research](2026-10-12-jido-runtime-simplification.md). The support/research pilot is a hypothetical use case, not an implemented capability or platform domain. The core persistence and external-effect findings remain relevant; use the current design for implementation direction.

## Recommendation

Keep Hermitscale's Postgres operation ledger, Oban reconciliation, Runic workflows, and persistent Codex conversation Sprite as the initial architecture. Jido provides useful agent coordination machinery, but its checked core persistence does **not** establish durable external-effect execution or restart-safe human approval continuation. Consider it later within `Hermitscale.Agents` for bounded noncoding agents or when several independently supervised agents need coordination. This is an architectural assessment, not a claim that Jido cannot be extended to meet these requirements.

Three GPT-6.1 Sol research agents examined core recovery, the existing workflow engine, and Codex composition. The recommendation is to defer framework adoption for the initial Codex product, retain a narrow integration option, and evaluate packages individually. No dependency was added or design decision changed by this assessment.

| Product need | Recommended implementation |
| --- | --- |
| Codex chat and coding workflow steps | Existing proposed Agents interface and direct Codex runner. |
| Durable workflow waits and retries | Runic integration plus Postgres external operations and Oban. |
| Persistent Sprites and published apps | Hermitscale Workspaces and Apps, including retention and data policy. |
| Future support or research agent choosing among several tools | Candidate for a bounded Jido AI pilot behind Agents. |
| Supporting several coding CLIs | Evaluate Jido Harness separately when that becomes a requirement. |

## Verified core capabilities

Jido separates an immutable agent struct and state transitions from `AgentServer`, a GenServer that routes signals and executes directives. Actions may perform immediate I/O; directives describe runtime-owned effects such as emitting, spawning, scheduling, and stopping. Plugins bundle capabilities; strategies control execution. This offers an inspectable, testable decision interface and explicit process ownership. It does not make effectful actions pure or automatically durable. [Core loop](https://github.com/agentjido/jido/blob/v2.4.0/guides/core-loop.md), [runtime source](https://github.com/agentjido/jido/blob/v2.4.0/lib/jido/agent_server.ex)

`InstanceManager` supplies keyed lookup, starting or thawing agents, attachment tracking, and optional idle hibernation. Idle timeout defaults to infinity. Missing checkpoints start fresh agents; other thaw errors fail the manager's `get` path instead of silently starting fresh. This can reduce repeated lifecycle code, but an attachment to a BEAM process is distinct from a bounded Sprite task hold. [InstanceManager](https://github.com/agentjido/jido/blob/v2.4.0/lib/jido/agent/instance_manager.ex)

## What persistence actually recovers

| Boundary | Verified behavior | Implication for Hermitscale |
| --- | --- | --- |
| Agent snapshot | Default checkpoint contains version, module, ID, state excluding the full thread, and a thread ID/revision pointer. Custom callbacks control serialization. | Store only redacted state and references; a snapshot is not the product operation ledger. |
| Journal and thaw | Hibernate flushes missing journal entries before writing the snapshot. Thaw calls restore, loads the thread, checks revision equality, and reattaches scheduler state. Default restore constructs an agent and merges saved state. | Core thaw does not replay actions/tools. Custom restore/plugin behavior must still be audited for effects. |
| Live runtime | Directive queues, deferred signals, children, and completion waiters are separate `AgentServer.State` fields initialized empty on startup. | A saved waiting status does not reconstruct pending delivery, task ownership, or a protocol response handle. |
| Idle and termination | Keyed lifecycle hibernates on clean termination with storage enabled. This is not a write after every state change or protection against abrupt host loss. | Recovery can return to an older checkpoint; durable intent must precede external work. |

These conclusions follow the **implemented paths**, rather than interpreting “replayable journal” as an effect-replay guarantee. [Persist v2.4.0](https://github.com/agentjido/jido/blob/v2.4.0/lib/jido/persist.ex), [server state v2.4.0](https://github.com/agentjido/jido/blob/v2.4.0/lib/jido/agent_server/state.ex), [keyed lifecycle v2.4.0](https://github.com/agentjido/jido/blob/v2.4.0/lib/jido/agent_server/lifecycle/keyed.ex)

There is a narrower durability feature for dynamic cron manifests: managed registration/cancellation is persisted and restored; missed runs are not replayed. It should not be generalized to arbitrary directives. [Storage guide](https://github.com/agentjido/jido/blob/v2.4.0/guides/storage.md)

**Inference for approval recovery:** Hermitscale still needs a persisted approval identity, exact target digest, authorized actor, expiry, continuation identity, and fencing. On restart it must inspect the runner/Codex state and resume one permitted continuation. Jido state can represent the wait; core thaw alone cannot prove the remote request remains answerable. Likewise, a push, deployment, or customer reply that succeeded just before a crash needs provider reconciliation before retry. No exactly-once external-effect guarantee was found in these inspected core paths.

## Storage and release qualification

ETS is the default and loses data on restart. Core also supplies File and Redis adapters. File is documented for simple production, uses temporary-file rename for checkpoints and locking for journal append; it is not a shared Postgres transaction with Hermitscale records. Redis requires a supplied client and its own durability configuration. Hermitscale's authoritative store should remain Postgres. [Storage guide](https://github.com/agentjido/jido/blob/v2.4.0/guides/storage.md), [File adapter](https://github.com/agentjido/jido/blob/v2.4.0/lib/jido/storage/file.ex)

An Ecto adapter **exists**: `jido_ecto` implements checkpoints, ordered journals, snapshots, and optimistic append concurrency using an existing Repo, with PostgreSQL and SQLite coverage. However, its live README explicitly calls it alpha quality and says **“Do not rely on this package in production yet.”** It also announces planned deprecation into an opt-in Jido 3.x integration. The working adapter and an ecosystem maturity label are not evidence of operational qualification. [Package README](https://github.com/agentjido/jido_ecto/blob/main/README.md), [dependency requirements](https://github.com/agentjido/jido_ecto/blob/main/mix.exs)

Hex lists stable **2.4.0** and **3.0.0-beta.1**, while some cached official docs/main responses still show 2.3.3. Prefer exact release source when evaluating adoption. The v2 line became stable in February 2026; subsequent fixes include storage, thaw errors, and sync-call races. This shows active maintenance and also makes recovery regression tests necessary. [Hex releases](https://hex.pm/packages/jido), [changelog](https://github.com/agentjido/jido/blob/v2.4.0/CHANGELOG.md)

Jido 2.4.0 requires Elixir `~> 1.18`, matching Hermitscale. Its requirements for telemetry and telemetry_metrics are compatible with this repository's declared ranges and current locked versions. It adds Jido Action/Signal, Zoi, Poolboy, scheduling, and timezone dependencies. `jido_ecto` targets Jido `~> 2.4` and Ecto/SQL `~> 3.13`, overlapping Hermitscale's ranges. This is a manifest compatibility check; **no dependency resolution, compilation, or runtime integration was performed**. [Pinned core manifest](https://github.com/agentjido/jido/blob/v2.4.0/mix.exs), [local manifest](../../mix.exs), [local lockfile](../../mix.lock)

## Fit with the existing workflow engine

Hermitscale already owns versioned node schemas and configuration, definition identity, input occurrence lineage, provider dependencies, explicit failure mapping, Postgres execution history, and definition-compatible replay. Trigger deadlines and dispatch jobs already use Postgres and Oban. Replacing these mechanisms solely to start Codex would create migration work without removing the remote recovery problem. [Node definition](../../lib/hermitscale/workflows/nodes/behaviour.ex), [native node adapter](../../lib/hermitscale/workflows/engine/node.ex), [workflow storage](../../lib/hermitscale/workflows/postgres_store.ex), [replay](../../lib/hermitscale/workflows/replay.ex), [scheduler](../../lib/hermitscale/triggers/scheduler.ex)

Jido.Runic is a real integration with Runic, including action nodes, signal/fact conversion, and a strategy that dispatches runnables and applies their results. Its existence makes selective composition plausible; it does not establish durable remote waits. Current main declares version 1.0.1 with Runic `~> 0.1.0-alpha.10`, whereas Hermitscale pins a Git revision. Its strategy also tracks completed nodes by node hash, so repeated mapped occurrences require a regression test against Hermitscale's identity semantics. These are compatibility questions, not proven defects. [Jido.Runic manifest](https://github.com/agentjido/jido_runic/blob/main/mix.exs), [strategy source](https://github.com/agentjido/jido_runic/blob/main/lib/jido/runic/strategy.ex), [Hermitscale lockfile](../../mix.lock)

Keep `Workflows.ExternalOperations` responsible for waiting and accepting terminal results. A Jido action result or asynchronous directive must not be mistaken for an accepted durable wait. Map rejected or failed actions explicitly to the existing `SingleOutput.Result.failure` contract: an ordinary error tuple is otherwise ordinary node output. Keep Runic structs, Jido directives, and process IDs out of persisted workflow facts.

## Codex and Harness composition

Codex app-server already supplies the coding conversation, tool activity, approval requests, and turn control required by the proposed UI. An outer Jido AI loop would add another model choosing when to call or retry Codex. That is useful only when it has a distinct business planning task; otherwise it duplicates reasoning, histories, budgets, and cancellation decisions. Retain the phase 0 protocol/support spike for the direct integration itself. [Official Codex app-server documentation](https://learn.chatgpt.com/docs/app-server)

The package names hide a material version change:

- **Jido Codex is deprecated and archived.** The repository was archived on July 17, 2026, and directs new development to Harness. Its older exec/app-server examples should not guide a new dependency choice. [Jido Codex README](https://github.com/agentjido/jido_codex)
- **Current Harness v3 uses ACP.** It manages coding CLI lifecycle through ExMCP and does not require Jido core or Jido AI. Its README explicitly leaves durable jobs to the host; runs and sessions do not survive BEAM or host restart. [Harness README](https://github.com/agentjido/jido_harness)
- **Protocol coverage differs from native Codex.** Current provider docs use `codex-acp`, report no steering or structured-output support in the ACP profiles, and distinguish profile capabilities from the underlying CLI. The migration guide explains that raw events are ACP translations, so omitted native fields are not recoverable from that envelope. [Provider capabilities](https://github.com/agentjido/jido_harness/blob/main/guides/providers.md), [v3 migration](https://github.com/agentjido/jido_harness/blob/main/guides/migrations/migration_v3.md)

The documented Harness architecture starts a local ACP executable; it does not establish a ready-made remote Sprites transport. Running Harness inside a Sprite or relaying ACP through an authenticated transport is a possible custom integration, requiring deployment and recovery work. A future comparison must demonstrate equivalent product capabilities and less maintained code before replacing the runner. [Harness architecture](https://github.com/agentjido/jido_harness/blob/main/guides/reference/architecture.md)

## Sprite persistence and lifecycle fit

Jido Shell has a Sprite backend, but its ownership mode matters: `create: true` marks the Sprite as owned and termination attempts to destroy it; `create: false` attaches without deleting it on teardown. Any reuse must let Hermitscale provision and retain the Sprite, attach for bounded work, and delete only through retention policy. The inspected backend also returns success when the SDK lacks a network-policy method, so policy enforcement needs separate verification before relying on it. [Sprite backend source](https://github.com/agentjido/jido_shell/blob/main/lib/jido_shell/backend/sprite.ex)

Jido Workspace's README explicitly excludes Sprite workflow orchestration; its default example uses an in-memory virtual filesystem. Artifact snapshots are not evidence of persisted checkouts, dependency caches, Sprite recovery checkpoints, or published SQLite backup policy. These remain Workspaces and Apps responsibilities. [Workspace README](https://github.com/agentjido/jido_workspace)

Framework process state, remote filesystem persistence, and external-effect history solve different problems. None substitutes for the others. Closing Jido or Harness transports must release compute activity while preserving stored files. History views remain database reads. A local orchestration agent must not poll an idle Sprite to keep its own state current. Adding a reasoning agent also adds model usage; it does not reduce persistent storage costs.

## Historical hypothetical pilot

The assessment considered a support investigation agent behind `Hermitscale.Agents`, with a small set of permitted evidence tools and a fixed iteration and model budget. It may gather context and draft a response; publication, deployment, and sending remain explicit Hermitscale operations. Compare its quality and implementation effort against a fixed workflow with the existing Responses node. Use Codex delegation only for an actual repository investigation.

This pilot was not adopted as a platform contract. Similar tasks can be composed from ordinary provider and agent nodes. The hypothetical module name is not an instruction to add a support context, and the package analysis does not justify a second product history or framework abstraction.

Before accepting either a Jido or Harness integration, demonstrate:

1. Phoenix restart and Sprite cold boot reconnect to one existing operation and retained checkout.
2. Approval waits release holds; an authorized answer resumes one continuation after revalidation.
3. Duplicate events and ambiguous external effects do not repeat a PR, deployment, or message.
4. Two identical mapped workflow inputs remain separate occurrences.
5. History reads and idle agent processes cause no Sprite exec, polling, or task-hold renewal.
6. Required chat controls, event evidence, and result validation survive any protocol translation.
7. Compute, storage, and each reasoning loop's model usage remain separately attributable.

## Concrete value and limits

- **Useful when justified:** typed agent state, explicit effects, signals, reusable plugins, bounded coordination, supervision, and keyed lifecycle. A later support triage agent could use these without replacing the coding runner.
- **Additional layer:** Jido AI supplies LLM orchestration through ReqLLM; it is optional and separate from core. Adopting it is a separate decision from wrapping externally hosted Codex. [Jido AI manifest](https://github.com/agentjido/jido_ai/blob/main/mix.exs)
- **Product-owned work remains:** tenant authorization, connection delivery, Postgres operation/event ledger, workflow occurrence identity, approved publication, deployment promotion, customer delivery reconciliation, and Sprite retention/sleep policy.
- **Preserve resource ownership:** Jido process hibernation is not Sprite suspension or a filesystem checkpoint. Continue **create → work → sleep → resume** on the same retained conversation Sprite; keep published environments separate. A framework adapter must not delete a retained workspace on agent shutdown.

Before adoption, prove restart during an external mutation, lost terminal response, durable approval sleep/resume, stale approval rejection, concurrent admission fencing, and recovery after journal flush but before checkpoint write. A Jido spike should consume the existing ledger through the public contexts and demonstrate reduced complexity; passing agent-state round trips alone is insufficient.
