# Private workspace protocol v1

The host and worker share this local Mix dependency. `Hermitscale.WorkspaceProtocol.V1`
validates exact JSON envelope keys, identity, type-specific payloads, SHA-256
digests, UTC deadlines and transfer limits. JSON schemas document the envelope;
the Elixir validator additionally enforces payload/digest/deadline semantics.

Canonical payload JSON sorts object keys lexically, uses compact UTF-8 JSON,
and preserves array order. `payload_digest/1` returns lowercase SHA-256 hex.
Both runtimes consume `fixtures/start.json` and `fixtures/event.json` in tests.
Commands carry required `deadline`; inspect/replay are bounded requests as well.
Validate with `now: DateTime.utc_now()` before admitting a new command. Already
accepted duplicate commands may return their recorded status after expiry,
without executing their effect again.

Events carry `workspace_id`, `operation_id`, `epoch` and positive `cursor`.
Their product source identity is `workspace_id:epoch:cursor`. Ordinary restarts
preserve the epoch and append explicit recovery uncertainty at the next cursor.
Only fenced checkpoint recovery can begin a new epoch. Old epoch pages remain
readable until an explicit retention boundary; unknown epochs return history_gap.
Persist redacted events in the host before advancing acknowledgment. Reaching
local storage limits is a failure, never successful silent history rotation.

This protocol is private. It carries no Sprite name, fleet credential,
arbitrary executable, provider config or workflow authority. The host resolves
authorized product IDs before sending commands through a qualified transport.
