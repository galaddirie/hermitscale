# Hermitscale Agents and Apps Software Design

Status: Current platform contract after the October 13, 2026 scope cleanup.

Implementation: [Agents and Apps implementation](agent-apps-implementation.md).

Hermitscale lets users run coding conversations, build and publish apps, and compose
those operations into workflows. Jido coordinates active conversations; Jido
Harness runs Codex in a private Elixir worker on a retained Fly.io Sprite. Shell
and VFS provide workspace operations. Postgres and Oban own durable intent,
history, dispatch and reconciliation; Runic remains the workflow engine.

A ticket triggering a repository edit or app update is an example of a
user-authored workflow. Such examples do not define platform contexts, case
records, reply policies, subscription mappings or a separate review product.
Existing provider triggers and actions remain independently composable.

## Ownership

| Owner | Responsibility |
| --- | --- |
| `Agents` | Private sessions, admitted turns, history, cancellation, provider continuation, optional result contracts and branch publication |
| `Agents.Approvals` | Native coding-runtime permission requests bound to the current turn and its executing actor |
| `Workspaces` | Retained Sprite identity, provisioning, recipes, fenced leases, command/file access, verified termination and retention |
| `Apps` | Build conversations, previews, isolated access, immutable release artifacts, promotion, persistent data and recovery |
| `Workflows.ExternalOperations` | Durable waits and terminal acceptance for agent/app operations against an admitted Runic definition and input occurrence |
| `Integrations.ExecutionAccess` | Selected provider access, expiring capabilities, model budgets and current actor validation |
| `Artifacts` and `Usage` | Authorized stored evidence and separate compute, storage and model accounting |
| `ProductTools` and ExMCP | Authenticated tools over the public contexts |

Jido state is a disposable projection of committed records. Package handles,
process IDs and credentials stay outside persisted workflow facts. The worker
owns local command acceptance, fencing, Harness interaction and its event journal;
it does not own organization permissions, workflow state or fleet credentials.

## Conversations and workspaces

A session owns one retained editing Sprite. Turns serialize work in that workspace
and retain their execution actor, instructions, operation key, budget, deadline
and outcome. A keyed retry cannot replace the admitted instructions or settings.
Follow-ups reuse files, dependencies, uncommitted changes and retained provider
history. New repository sessions identify a permitted repository and starting
commit; new-app sessions can begin with the blank app recipe.

The lifecycle is **create → work → sleep → resume**. Completion, cancellation,
closure and archival do not delete files. Cancellation stays pending until writer
termination is verified. Stored history and artifacts do not require a Sprite
wake. Remote commands, previews and deliberately scheduled jobs require activity
authorization and bounded leases. Workspace deletion is a separate operation that
checks active work and resource protections.

A normal chat turn accepts conversational output. `result_schema` is optional;
a nonempty schema requests a JSON result artifact and host validation.
`verification_commands` is also optional and records the checks selected for that
turn. The platform does not impose a repository's test command or a fixed
business-result schema on every conversation. Agent summaries alone do not prove
that checks passed or a remote effect completed.

Native permission prompts use `Agents.Approvals`, rather than a global review
inbox. A decision belongs to the pending turn, exact request digest, executing
actor and deadline. The actor's conversation access and `agents:run` permission
are revalidated before the answer reaches the worker. A stale or rejected prompt
cannot authorize a different action. An uncertain remote turn is inspected before
any restart; recovery does not blindly repeat model work.

## Publication and workflows

Branch publication is an explicit `agents:publish` request. It binds the selected
manifest, branch, base revision and message to retained patch evidence. The
publisher is revalidated at execution; remote commit/ref evidence determines
completion. Stable operation keys retain known and uncertain outcomes. A coding
turn preparing changes does not itself publish them.

The durable agent/app node catalog contains:

- `agents.codex.run`
- `agents.publish_branch`
- `apps.preview.create`
- `apps.deploy`
- `apps.logs.read`

These nodes call their owning contexts outside the workflow transaction and wait
for owner-recorded outcomes. A pending operation has no successful node output.
The reservation binds the admitted definition, component, activation, input
occurrence and mapped lineage. Terminal acceptance and consumed reservations
commit with the accepted native Runic events. Duplicate completion cannot create
a second accepted output for the same occurrence.

Existing GitHub, Linear and other provider nodes retain their normal integration
contracts. They are not forced through a ticket-specific delivery subsystem or a
fixed trigger → coding → PR → reply pipeline. Workflow authors select the nodes,
connections, instructions and effect policies appropriate to their use case.
Provider actions do not inherit an exactly-once delivery guarantee from the agent
runtime. Definition edits apply to future runs; an admitted run uses its snapshot.

## Apps, release isolation and data

An app has stable identity, build conversations, environments and deployment
history. Editing and preview run in a build workspace. Published environments
use separate persistent Sprites, so later edits cannot change the active release.
The `python-sqlite-v1` starter provides a blank page, health/revision reporting and
SQLite initialization; it installs no sample business tables or application API.

A deployment request requires current `apps:deploy` authority and records the
source commit, checksummed source artifact, configuration digest and expected
active deployment. A repeated key retains the same immutable intent. Promotion
serializes against the environment's release operation and expected prior release;
an older request cannot replace a newer deployment. Publication and data recovery
are explicit actor actions, without a separate reviewer role or review record.

Release code lives in versioned directories. SQLite, WAL files and uploads live
outside them. Preview data never replaces published data. Releases stage and
verify code, export independent integrity-checked backups where required, switch
the managed service and verify the served revision before recording promotion.
An uncertain activation is reconciled from the release marker and served state.

Code rollback uses a previous artifact with current customer data. Data recovery
is a separate keyed request for an exact backup and expected active deployment.
It fences writers, places the environment in maintenance, restores and verifies
data, then restarts the recorded release. Automatic destructive migrations and
whole-Sprite restore are not ordinary code deployment. SQLite hosting remains a
single-serving-Sprite profile; broader availability promises require a separate
design and qualification.

Preview grants expire independently of retained files. Public access is an
explicit `apps:deploy` choice against the verified active release. App traffic
uses an isolated gateway on a different registrable domain from the control
plane, including HTTP and WebSocket traffic without forwarding control-plane
cookies. Opening a preview is deliberate; rendering history does not load it.

## Authentication, connections and MCP

Use the existing WorkOS identity model and organization-owned Pipes connections.
All public contexts take verified `current_scope` first. Jobs reconstruct the
recorded actor and revalidate current membership and operation permissions.
Selected provider accounts retain their actual provider scopes and expiry;
selecting one repository does not narrow a broad provider token.

Browser `/agents`, `/apps` and `/workflows` screens are in `scope "/",
HermitscaleWeb`, through `[:browser, :require_authenticated_user]`, inside the
single `live_session :require_authenticated_user`. HTTP entry and LiveView
reconnect therefore verify membership and assign `current_scope`. Landing and
sign-in callbacks remain in the public browser scope. Templates use `Layouts.app`
with `current_scope`; forms and collections follow the repository's Phoenix rules.

Fleet credentials and durable model keys remain on the host. An authenticated
fixed-upstream inference gateway vends expiring turn capabilities and meters
model usage. Published apps have a separate runtime access profile. Credentials
must not enter artifacts, recipes, Git remotes, workflow facts or saved events.

ExMCP exposes `/mcp` outside the browser and JSON-only API pipelines so it owns
JSON/SSE negotiation. Bearer capabilities constrain organization, resources,
actions and calls; each request revalidates the bearer and current actor. Legacy
sessions are bound to their capability and organization. Tools cover workflows,
runs, conversations, app builds/previews/logs and deployment requests. They do
not expose provider proxy tools or example-business domains. Keyed mutations use
the same context admission rules as the UI and workflow nodes.

## Verification and compatibility

Test public contexts, workflow occurrence identity, authorization, worker journals,
lease fencing, cancellation, native permission prompts, release concurrency and
backup/restore behavior. Fake providers and transports prove these contracts;
they do not establish paid model execution or production cloud availability.
Run `mix precommit` for the host and the worker's documented checks separately.
Pinned package changes require renewed protocol, recovery and operating checks.
See [implementation evidence](agent-apps-implementation.md) and the
[historical package research](research/2026-10-12-jido-runtime-simplification.md).

The cleanup migration copies native agent-turn permission rows into
`agent_approvals`, removes the retired review/support/delivery tables and their
records, drops investigation-source session metadata, and revokes capabilities
for the retired tools. Existing workflows containing removed example-domain node
IDs must be edited before they can run under the current catalog.
