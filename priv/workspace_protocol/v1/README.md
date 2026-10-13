# Private workspace protocol v1

The host and worker share this local Mix dependency. `Hermitscale.WorkspaceProtocol.V1` validates JSON envelope identity, command payloads, SHA-256 digests, UTC deadlines and transfer limits.

Canonical payload JSON sorts object keys lexically and preserves array order. Commands require a deadline. Already accepted duplicates can return recorded status after expiry without executing their effect again.

Events carry `workspace_id`, `operation_id`, `epoch` and a positive `cursor`. Ordinary restarts preserve the journal epoch and append recovery uncertainty. Reconnects read from the last persisted cursor; unknown epochs return `history_gap`. There is no acknowledgement or checkpoint-recovery protocol. Reaching the journal storage limit fails rather than silently losing history.

This private protocol carries no fleet credential, arbitrary executable or workflow authority. The host resolves authorized workspace identities and current leases before sending commands through authenticated Sprite exec.
