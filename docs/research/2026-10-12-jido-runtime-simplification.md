# Jido runtime simplification for Agents and Apps

Date: October 12, 2026. Scope: simplifying the proposed [Agents and Apps design](../agent-apps-design.md). This note checks current first-party source; it does not install dependencies or claim runtime qualification. It complements the earlier [Jido assessment](2026-10-12-jido-agents-apps-assessment.md) with a concrete reuse topology.

## Recommendation

Use Jido core for the active conversation coordinator, Shell and VFS for supported Sprite command/file operations, and evaluate Harness inside a small Elixir worker on each conversation Sprite. This can remove bespoke process management and protocol translation from the proposed runner. Keep Hermitscale's durable operations, authorization, resource ownership, and deployment rules. This is a proposed composition of existing library interfaces, not an upstream turnkey integration.

Do not add an outer Jido AI reasoning loop merely to invoke Codex. `Jido.Agent` supplies state transitions and a supervised runtime without requiring a model; `Jido.AI.Agent` separately supplies model/tool reasoning. Native Jido AI agents become useful when a support or research task has its own reasoning requirements. [Core loop](https://github.com/agentjido/jido/blob/ca607209f9c4731dd506985034ab895f922f2d23/guides/core-loop.md), [Jido AI overview](https://github.com/agentjido/jido_ai/blob/3d422271202aa4f01181cf30df3e23cc01b4dd96/README.md)

## Source and release qualification

These revisions were resolved directly through GitHub's API and their source downloaded for inspection, avoiding mixed-age search results. A manifest version on `main` does not establish that all inspected code shipped in the same-numbered release.

| Package | Inspected revision and declared version | Release evidence |
| --- | --- | --- |
| Jido core | [`ca607209`](https://github.com/agentjido/jido/tree/ca607209f9c4731dd506985034ab895f922f2d23), `2.4.0` | Hex lists stable `2.4.0` and `3.0.0-beta.1`; qualify the stable line first. [Hex API](https://hex.pm/api/packages/jido) |
| Jido AI | [`3d422271`](https://github.com/agentjido/jido_ai/tree/3d422271202aa4f01181cf30df3e23cc01b4dd96), `2.4.0` | Hex lists `2.4.0`. Optional for the proposed Codex composition. [Hex API](https://hex.pm/api/packages/jido_ai) |
| Harness | [`2cea7100`](https://github.com/agentjido/jido_harness/tree/2cea7100174de3aae3ece358612f2405a175217f), `3.0.0-rc.1` | README explicitly recommends a Git dependency for this candidate. Public Hex API returned HTTP 404 during this check. [README](https://github.com/agentjido/jido_harness/blob/2cea7100174de3aae3ece358612f2405a175217f/README.md), [Hex endpoint](https://hex.pm/api/packages/jido_harness) |
| Shell | [`3c9af797`](https://github.com/agentjido/jido_shell/tree/3c9af797d1f2c852e2b182e77509fafc5b51f86b), `3.0.0` | README advertises `~> 3.0`, but public Hex API returned HTTP 404. Treat installation availability as unverified and qualify a fixed Git revision. [Manifest](https://github.com/agentjido/jido_shell/blob/3c9af797d1f2c852e2b182e77509fafc5b51f86b/mix.exs), [Hex endpoint](https://hex.pm/api/packages/jido_shell) |
| VFS | [`276fbe4d`](https://github.com/agentjido/jido_vfs/tree/276fbe4dcb025a87e7b33b2b23b84c0209dbd026), `1.0.1` | Hex lists `1.0.1`; compare the release artifact with inspected source before adopting its Sprite implementation. [Hex API](https://hex.pm/api/packages/jido_vfs) |

Harness requires Elixir `~> 1.19`; compilation builds its native process helper with `make`, a C++17 compiler, and Erlang headers. Package a pinned Linux worker release instead of compiling it on every turn. Core, Shell, VFS, and AI currently declare Elixir `~> 1.18`. No dependency resolution or build was performed. [Harness manifest](https://github.com/agentjido/jido_harness/blob/2cea7100174de3aae3ece358612f2405a175217f/mix.exs), [Harness installation](https://github.com/agentjido/jido_harness/blob/2cea7100174de3aae3ece358612f2405a175217f/README.md)

## What can replace custom machinery

| Proposed custom machinery | Library reuse | Hermitscale code still needed |
| --- | --- | --- |
| Conversation process lookup, signal dispatch, state transitions, supervision | `Jido.Agent`, `AgentServer`, `InstanceManager` | Domain actions, durable admission/fencing, rebuilding active state from authoritative records. |
| Coding CLI subprocesses, protocol parsing, resource events, approval handles, interruption | Harness sessions and ExMCP ACP | Worker control boundary, operation identity, persistence acknowledgements, authorization and provider qualification. |
| Sprite shell execution and session output | Shell Sprite backend | Authorized attachment, verified deadlines/cancellation/network enforcement, operation evidence. |
| File read/write/list/stat and checkpoint plumbing | VFS Sprite adapter | Access checks, limits, recovery fencing, checkpoint ownership and retention. |

Core provides keyed process lifecycle, including starting or thawing agents and idle hibernation. Its state model can coordinate a turn without another LLM. Model the coordinator as a cache of committed domain state; correctness must not depend on finding the same PID after restart. [InstanceManager source](https://github.com/agentjido/jido/blob/ca607209f9c4731dd506985034ab895f922f2d23/lib/jido/agent/instance_manager.ex)

## Concrete process placement

```text
Phoenix: Agents + Postgres + Oban + Jido coordinator
  -> private, authenticated worker control channel
     Conversation Sprite: small Elixir worker -> Harness -> codex-acp -> Codex
  -> Workspaces: Shell Sprite backend / VFS Sprite adapter / management API
```

Harness manages a local executable. Its architecture delegates ACP encoding, parsing and request correlation to ExMCP. It does not document a built-in Shell/Sprite transport connecting a remote ACP session. **Inference:** placing Harness beside the coding CLI inside the Sprite offers the clearest reuse boundary; a remote ACP relay would introduce additional custom transport work. Keep the fleet token in the trusted Phoenix control plane. [Harness architecture](https://github.com/agentjido/jido_harness/blob/2cea7100174de3aae3ece358612f2405a175217f/guides/reference/architecture.md)

Shell should attach to the same retained Sprite with `create: false`. Its `create: true` branch takes ownership and teardown attempts to destroy the Sprite. Keep allocation/deletion, services, task holds, retention, preview routing and published-environment lifecycle in Workspaces/Apps. Shell's local virtual shell, its restricted Bash backend, and a remote Sprite OS shell are different execution environments; do not infer one backend's isolation from another's description. [Shell backend source](https://github.com/agentjido/jido_shell/blob/3c9af797d1f2c852e2b182e77509fafc5b51f86b/lib/jido_shell/backend/sprite.ex), [Shell backends](https://github.com/agentjido/jido_shell/blob/3c9af797d1f2c852e2b182e77509fafc5b51f86b/README.md)

## Required boundaries

**Harness capability translation.** Current built-in profiles use ACP; Codex runs through the separate `codex-acp` adapter. The checked provider guide pins adapter `1.6.2`, advertises neither steering nor structured output, and warns that translated events can omit native fields. The profile's maturity label is not evidence of a particular live CLI test. The documented Codex isolation controls are unsupported by that pinned adapter. Keep structured result validation in Hermitscale and prove all required chat interactions before replacing direct app-server integration. [Provider guide](https://github.com/agentjido/jido_harness/blob/2cea7100174de3aae3ece358612f2405a175217f/guides/providers.md)

**Approvals and cancellation.** Harness sessions accept approval responses, queue follow-ups, interrupt active turns, and separate caller wait timeouts from execution timeouts. Closing a session denies unresolved approvals. These APIs can replace local protocol mechanics, while Hermitscale still binds each decision to the authorized actor, action digest, expiry and durable operation. An application restart cannot be assumed to preserve a pending provider permission request. [Session guide](https://github.com/agentjido/jido_harness/blob/2cea7100174de3aae3ece358612f2405a175217f/guides/interactive_sessions.md)

**Durability.** Harness explicitly excludes surviving BEAM/host restart. Its bounded disk journal can rotate and can fail while execution continues in memory. Thus reuse its event stream, but persist acknowledged product events and accepted command identities separately; do not adopt the Harness journal as the durable broker. Core checkpoints restore agent state and thread references, with ephemeral ETS as the default. Neither facility establishes exactly-once remote effects. [Harness retention](https://github.com/agentjido/jido_harness/blob/2cea7100174de3aae3ece358612f2405a175217f/guides/streaming_replay_and_retention.md), [Core storage](https://github.com/agentjido/jido/blob/ca607209f9c4731dd506985034ab895f922f2d23/guides/storage.md)

**Sprite safeguards.** Shell currently accepts unsupported network-policy SDK operations as successful. Cancellation attempts `close_stdin` and `kill` and does not establish that every remote descendant stopped. Its adapter is reusable plumbing, but Hermitscale must verify network controls and cancellation against the chosen SDK and enforce its own deadline and reconciliation contracts. [Shell Sprite implementation](https://github.com/agentjido/jido_shell/blob/3c9af797d1f2c852e2b182e77509fafc5b51f86b/lib/jido_shell/backend/sprite.ex)

**Checkpoint scope.** VFS Sprite version operations map to whole-Sprite checkpoints. `restore_version` ignores the supplied file path. More surprisingly, `read_version` creates a temporary checkpoint, restores the requested checkpoint, reads the file, then restores the temporary checkpoint. **Inference:** expose this only through fenced workspace recovery, never as an ordinary historical-file read on an active checkout or published SQLite environment. Use Git history or exported artifacts for passive history views. [VFS Sprite implementation](https://github.com/agentjido/jido_vfs/blob/276fbe4dcb025a87e7b33b2b23b84c0209dbd026/lib/jido_vfs/adapter/sprite.ex)

**Security and isolation.** Harness runs with the worker's OS permissions. Environment replacement limits inherited variables but does not create filesystem or network isolation. Shell/VFS names and prefixes also do not establish tenant authorization. Keep the Sprite boundary and Hermitscale access checks; ensure the worker has no fleet-management credential. [Harness security](https://github.com/agentjido/jido_harness/blob/2cea7100174de3aae3ece358612f2405a175217f/guides/security.md)

## Qualification before committing to implementation

1. Pin dependency and CLI revisions; build the worker once and verify package compatibility.
2. Run a real Codex session in one retained Sprite: stream evidence, answer an approval, cancel work, resume another turn, and preserve checkout/cache state.
3. Restart Phoenix and the worker separately during an accepted turn and an approval wait. Recover one operation or record an explicit interruption; never blindly rerun an ambiguous effect.
4. Verify event persistence failure and replay gaps produce an explicit incomplete-history state.
5. Verify Shell attachment teardown retains the Sprite, cancellation stops remote work, and unavailable network-policy APIs fail closed at the Hermitscale boundary.
6. Confirm passive history reads and idle coordinators do not issue remote commands or renew task holds; qualify checkpoint operations under exclusive recovery ownership.

These are acceptance gates for library reuse. They preserve the intended simplification: upstream libraries own agent and protocol mechanics; Hermitscale owns product state and external effects.
