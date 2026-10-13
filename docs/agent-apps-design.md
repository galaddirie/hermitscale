# Hermitscale Agents and Apps Software Design

Updated October 13, 2026. [Operations](agent-apps-operations.md) describes the
current interfaces and configuration.

The platform runs coding conversations, composes them into user-authored Runic
workflows and starts user-built apps on retained Fly.io Sprites. Harness/Codex
runs in a private worker. Postgres and Oban own host history and dispatch;
Sprites provides persistent files, process services and URLs.

A ticket triggering edits in a repository or app is an example workflow. It does
not introduce support cases, subscription mappings, reply policies or a review
product. Existing provider triggers and actions remain independently composable.

## Ownership

| Module | Responsibility |
| --- | --- |
| `Agents` | Private sessions, immutable turn admission, ordered events, cancellation, native permission answers and explicit Git publication |
| `Agents.Approvals` | Exact native permission request, pending turn, executing actor and expiry |
| `Workspaces` | Retained Sprite allocation, bounded execution/file access, exclusive leases, worker control and verified termination |
| `Apps` | Owner/conversation association, selected start command/port, native service visibility, URL/status and deliberate logs |
| `Workflows` | Run admission and native Runic execution/history; coding nodes reuse keyed agent turns |
| `Integrations.ExecutionAccess` | Provider credential selection/vending and scoped MCP tokens |

There is no additional Jido coordinator or Shell/VFS wrapper layer on the host.
The worker uses Harness for coding-runtime interactions. Its acceptance journal
and the host's committed records serve distinct recovery purposes. Package
handles, PIDs and secrets remain outside saved workflow facts.

## Conversations and effects

A session owns one retained editing workspace. Follow-ups reuse its checkout,
changes, dependencies and provider conversation. Repository checkout may identify
an explicit commit or use the repository's default branch. New-app sessions start
with an empty Git workspace; no application business schema is imposed.

Turns retain instructions, operation identity, execution actor, deadline and
outcome. Admission and its dispatch job commit together. One writer lease fences
workspace mutation. Browser closure, completion and archival retain files;
cancellation remains pending until termination is verified. Stored history does
not contact the Sprite. Uncertain remote work is inspected before another start.

Ordinary chat does not require structured output or an evidence scan. A caller
may supply `result_schema` for a bounded JSON-result read and validation, or
`verification_commands` for explicit checks. Native provider events remain the
conversation history; optional checks do not become a universal success gate.

Native permission prompts are bound to the current turn, exact request, actor and
deadline. `agents:run` and conversation ownership authorize an answer after current
membership is checked. The worker receives one permitted continuation; a stale
prompt cannot authorize a different operation.

Explicit branch publication needs `agents:publish`, `branch`, `message` and
`operation_key`. A writer lease serializes ordinary Git commit/push. Actual remote
branch verification produces the result. Session request/result events bind keyed
retries, without an artifact manifest, registry or separate publication worker.

## Workflow composition

`agents.codex.run` waits for its owner-recorded terminal turn. Its admission key
identifies the run, node and input occurrence, including mapped lineage. Retries
reuse the same session and turn. Runic owns execution, retry policy and accepted
event history; agent records own coding progress and outcomes. Definition edits
apply to future runs.

Workflow start and resume run immediately through native Runic. Initial input
events and accepted execution history remain persisted. Automatic workflow
restart recovery is deferred; coding turns retain their own Oban dispatch.

`agents.publish_branch`, `apps.preview.create`, `apps.publish` and `apps.logs.read`
invoke the corresponding public operation. Existing provider nodes retain their
normal contracts. Authors choose triggers, accounts, instructions and effects;
there is no fixed ticket → agent → PR → reply engine or shared delivery ledger.

## Apps and access

An app links its owner to one retained coding conversation. The owner chooses a
start command and HTTP port. Preview starts a private native Sprite service;
publication explicitly enables its public URL and records the Git revision when available.
Stop and log reads are explicit operations. Reopening metadata does not start the
service or fetch live logs.

The service uses the conversation's retained workspace. It is not isolated from
later edits as a separate immutable deployment. Framework, build, schema,
migration and data-maintenance choices belong to the workload. The platform does
not impose a Python/SQLite recipe, backup scheduler, release artifact or rollback
state machine. Sprite persistence does not itself establish a tested database
backup or code-only rollback guarantee.

Generated content stays off the control-plane origin. Public apps use native
Sprite URLs. Private HTTP access uses an authenticated isolated-origin broker;
provider credentials stay server-side. This does not add a sharing-grant product
or a custom WebSocket hosting layer.

## Authentication and MCP

Use WorkOS identity and organization-owned Pipes connections. Public contexts take
verified `current_scope` first; jobs reconstruct and revalidate the recorded actor.
The worker receives the selected OpenAI API credential for normal provider
authentication. Host fleet credentials and private worker-control secrets remain
separate. No inference gateway, usage ledger, model pricing or monetary budget
is required to start or finish coding work.

Browser agent/app/workflow routes use the browser/authenticated pipelines and one
`live_session :require_authenticated_user` inside `scope "/", HermitscaleWeb` so
HTTP entry and LiveView reconnect verify membership. `/mcp` sits outside browser
and JSON-only pipelines so ExMCP owns JSON/SSE negotiation. Expiring tokens bind
organization, actor, actions, resources and call limits, with current authority
checked on execution. MCP exposes the same public context operations.

Test conversation admission, event replay, native permission answers, cancellation,
writer exclusion, provider authorization, Git verification, native service actions
and workflow occurrence identity. Run the host and worker checks separately.
Historical framework research records rejected alternatives; it is not a list of
modules or qualification gates the product must implement.
