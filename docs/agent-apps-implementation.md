# Agents and Apps implementation

Updated October 13, 2026. This describes the current
[platform design](agent-apps-design.md). Example ticket processing belongs in
user-authored workflows; the platform supplies reusable agent, app and provider
operations.

## Product paths

| Path | Owner and retained behavior |
| --- | --- |
| Sign-in | WorkOS identity, expiring OAuth state, opaque encrypted provider session and current organization membership |
| Coding conversation | `Agents` admits private sessions and immutable turns with connections, budgets, ordered events, continuation and cancellation |
| Native permission prompt | `Agents.Approvals` binds a worker request to the pending turn and executing actor; current conversation access and `agents:run` authorize its answer |
| Workspace execution | `Workspaces` allocates retained Sprites, installs a pinned recipe, fences exclusive writers and verifies termination before lease release |
| Workflow wait | `ExternalOperations` reserves one admitted Runic occurrence and durably accepts its owner-recorded terminal result |
| Branch publication | `Agents.Publications` binds an explicit manifest to patch evidence, revalidates `agents:publish`, and reconciles remote commit/ref state |
| App preview | `Apps` starts and verifies a build-workspace preview on deliberate use; isolated access grants expire separately from files |
| App release | `Apps` admits an immutable source artifact and configuration against the expected prior release, then verifies activation in a separate environment |
| Data recovery | Integrity-checked backups, code rollback preserving writes and explicitly requested backup restoration have separate operations |
| Product MCP | ExMCP serves context tools through expiring capabilities, resource/action limits, current actor checks and mutation idempotency |
| Usage | Deduplicated model tokens/cost, compute milliseconds and retained evidence bytes are accounted separately; compute/storage measurements remain unpriced |

Browser routes are `/agents`, `/agents/:id`, `/apps`, `/apps/:id`,
`/apps/:id/build`, `/apps/:id/deployments/:deployment_id`, `/workflows` and
`/workflows/:id`. They use `scope "/", HermitscaleWeb`, the browser/authenticated
pipelines and one `live_session :require_authenticated_user` so entry and
reconnect verify the active organization. Artifact downloads and capability
issuance share that authenticated boundary. There is no separate review inbox.

## Runtime contracts

The Phoenix-side Jido coordinator is reconstructed from Postgres. The private
Sprite worker uses Harness/Codex and retains its own acceptance/event journal.
Provider conversation IDs support follow-ups; uncertain work is inspected before
another provider start. Lease generations, deadlines, separate Unix identities,
private control and confined file access protect runtime operations.

Ordinary conversation output can be text. A nonempty `result_schema` requests a
JSON artifact and host validation. Caller-selected `verification_commands` are
optional; empty defaults do not run an application-specific test suite. Result
and check failures remain visible. Failed/interrupted turns retain available
partial evidence. Diffs, file metadata and private `workspace_file` exports are
accessible through the initiating conversation's authorization.

Initial workspaces clone the selected repository/commit or initialize the blank
app starter. Published source artifacts are release inputs; conversations do not
have an investigation-specific deployed-source bundle contract.

Publication retains a remote result before writer cleanup. Restart can finish
cleanup without another publication command. Completed keyed retries return the
retained result after current actor and private-session checks. Known refusals
retain a failed outcome; uncertain responses require remote evidence. Credentialed
Git effects run in an isolated bare store, excluding source hooks, filters and Git
configuration. A verified publication can advance the follow-up baseline without
changing the session's original admission identity.

App requests use current `apps:write` or `apps:deploy` authority. Deployment inputs
bind artifact/configuration digests and the expected prior release. The UI
prepares a concrete release or recovery action and admits it on the actor's
explicit confirmation. Execution revalidates the recorded actor; there is no
separate review ID or reviewer permission. Public access and data recovery also
compare the expected active deployment, and recovery retains exclusive writer
and maintenance fences.

The `python-sqlite-v1` recipe provides a blank starter with SQLite initialization
and health/revision reporting. Tests create their own sample data. Versioned
release code, production data and preview data remain separate. Backup exports
are independently checked, code rollback preserves later writes, and backup
restoration explicitly replaces data.

## Workflow acceptance

The locked Runic revision is `6e6373832c00aa9ec5d19faeae945b61e2db50b1`.
The durable driver uses `Workflow.prepare_for_dispatch/2` and
`Workflow.apply_runnable/2`, preserving native output metadata, mapped lineage,
input occurrence identity and accepted events. Pending work has no successful
output and blocks completion.

Admission commits the run, definition snapshot, initial events and dispatch job
atomically. A reservation identifies the exact definition, activation, input,
resolved request, owner resource and deadline. Owner dispatch runs outside that
transaction. Terminal outcome and notification commit first; accepted native
events and the consumed reservation then commit together. Repeated handoff cannot
accept a second output for the same occurrence.

Durable agent/app nodes are `agents.codex.run`, `agents.publish_branch`,
`apps.preview.create`, `apps.deploy` and `apps.logs.read`. GitHub PR, Linear comment
and other provider nodes remain ordinary standalone integrations. They are not
wrapped in a fixed application-specific publication/notification sequence or a
shared delivery ledger. Their own effect and retry contracts still matter.

Graph creation keys bind the author's raw intent before account selection. A
changed payload with that key is rejected. Activation requires backend
permission. Admitted runs use their definition snapshot; editor changes apply to
future runs. Stored run listings are scoped and bounded.

## MCP and configuration

[The bearer-authenticated HTTP mount](../lib/hermitscale_web/mcp.ex) delegates to
[the ExMCP handler](../lib/hermitscale/mcp/server.ex) and public contexts. ExMCP
owns JSON/SSE negotiation, modern discovery and legacy sessions. Each request
revalidates its capability; sessions bind capability and organization. Tool calls
check action/resource authority, retained call budgets and current permissions.
The route is outside browser and JSON-only API pipelines.

Tools cover workflow listing/inspection/validation/creation, run start/status,
conversation inspection/continuation/cancellation/publication, app
inspection/creation/build/preview/logs and deployment request/inspection. Keyed
creation, continuation and effect requests reject conflicting repeated intent.
The server callback deadline is five minutes for synchronous setup; clients
choose their own timeouts.

[The environment sample](../.env.example) and [README](../README.md) describe
WorkOS/Pipes accounts, host-only Sprite management, the reachable inference URL,
model/rate policy, isolated wildcard app gateway, webhooks and production release
settings. Package/runtime pins are in `mix.lock` and the
[worker packaging instructions](../workspace_worker/README.md).

## Cleanup migration

[The scope cleanup migration](../priv/repo/migrations/20261013132941_remove_example_workflow_domains.exs)
copies native agent-turn permission decisions into `agent_approvals`, then drops
retired review, support subscription/case and integration delivery tables and
records. It removes obsolete app review fields and conversation investigation
source metadata, and revokes capabilities advertising the retired tools.
Rollback restores the old schema and native permission decisions; it does not
recreate deleted example-domain records. Affected in-flight runs are cancelled and their reservations retired because
changed node code cannot replay the old fingerprints. Saved definitions with
removed nodes or review parameters become drafts and their triggers are disabled
until the author repairs and reactivates them. Ordinary valid provider definitions
remain available for new runs.

## Verification

Relevant suites cover [conversations and native prompts](../test/hermitscale/agents/),
[workspaces](../test/hermitscale/workspaces/),
[durable workflow waits](../test/hermitscale/workflows/external_operations_test.exs),
[apps and recipes](../test/hermitscale/apps/),
[product tools](../test/hermitscale/product_tools_test.exs),
[capabilities](../test/hermitscale/integrations/execution_access_test.exs) and
[MCP transport](../test/hermitscale_web/mcp_test.exs). Authenticated LiveView tests
exercise the same contexts. [Worker tests](../workspace_worker/test/) cover
acceptance, replay, fencing, cancellation and Harness interaction.

Run `mix precommit` for the host and the worker's documented checks separately.
Deterministic provider and transport fixtures establish integration contracts;
they do not claim paid Codex inference or production Sprite publication. Historical
October 12 Linux qualification exercised the pinned worker and actual Codex/ACP
against deterministic model responses; its scope and evidence remain in the
[worker documentation](../workspace_worker/README.md).
