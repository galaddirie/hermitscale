# Agents and Apps operations

Updated October 13, 2026. See [the design](agent-apps-design.md) for scope.

## Coding runtime

The host stores private sessions, turns, events and native permission requests.
`ReconcileWorker` calls `Agents` directly through Oban. A fenced workspace worker
runs Harness/Codex on a retained Sprite and journals accepted commands/events.
Follow-ups reuse files and provider history; uncertain work is inspected before
restarting. No host Jido coordinator, Shell/VFS wrapper or event-acknowledgement
subsystem is needed.

WorkOS verifies the current actor and Pipes vends selected provider credentials.
`ExecutionAccess.provider_env/2` returns the authorized `OPENAI_API_KEY`; the worker
uses normal provider authentication. `SPRITES_API_KEY` remains on the host. Model
rates, gateway URLs, proxy-specific provider settings and dollar budgets are not
configuration prerequisites.

Ordinary chat retains text/events without collecting file exports, artifact
snapshots or usage measurements. A nonempty `result_schema` requests one bounded
`.hermitscale/result.json` read and host validation. `verification_commands` are
caller-selected commands, not inferred tests. Cancellation and lease release
still require actual writer termination.

Native `Agents.Approvals` decisions belong to the pending turn and executing
actor. Current `agents:run` authority, exact request identity and expiry govern
continuation. They are not publication/deployment review records.

## Git and workflows

`Agents.publish_branch/3` accepts `branch`, `message` and `operation_key`. It checks
current `agents:publish`, records keyed request history, acquires a writer lease,
vends the selected GitHub credential and runs ordinary Git publication. A remote
branch read confirms the returned repository/branch/commit. Known success is
retained in session events before writer cleanup. Changed intent cannot reuse its
key. An unconfirmed effect is not reported as successful.

`agents.codex.run` runs as an ordinary Runic node and waits on its persisted agent
turn. A stable occurrence key reuses the session and turn on retry. Runic owns
accepted workflow history; `Agents` owns dispatch and coding outcomes.
`agents.publish_branch`, `apps.preview.create`,
`apps.publish` and `apps.logs.read` invoke their public contexts. GitHub, Linear and
other provider nodes remain ordinary independent integrations; they do not gain
an exactly-once guarantee from the coding runtime.

Run admission commits the initial Runic events, then starts native execution
immediately. Resume restores native Runic execution from stored history. Automatic
workflow restart recovery is deferred. Coding-turn dispatch uses the `agents`
queue through `Agents.ReconcileWorker`.

A ticket-triggered edit is a hypothetical authored workflow, not a product domain.
Graph keys bind authoring intent; admitted runs retain their definition snapshot.
Changing a definition affects future runs.

## Apps

`Apps` stores owner metadata, one coding-session reference, start command/port and
native service URL/status and optional Git revision. Starting a build creates or reopens that
conversation. Private preview and public publication start the owner's command as
a managed Sprite service; public publication requires `apps:deploy` as well as
write access. Stop and native log reads are deliberate actions.

The service and editing files use the same retained workspace. There are no
separate environments, deployment artifacts, release records, automatic database
backups or restoration controls. Workload authors manage their own build and data
operations. Existing Sprite files are retained through the schema cleanup.

Public access uses Sprite's URL. The private HTTP broker checks the current owner
and serves generated content on the isolated `APP_GATEWAY_HOST`; route that host
with TLS on a different registrable domain from `PHX_HOST`. Credentials remain
server-side. Custom sharing grants and WebSocket relays are absent.

## Browser, MCP and releases

Agent, app and workflow screens use `scope "/", HermitscaleWeb`,
`[:browser, :require_authenticated_user]` and one authenticated LiveView session.
That arrangement checks membership at entry and reconnect. `/mcp` uses an
independent token-authenticated mount for ExMCP's JSON/SSE negotiation and modern/
legacy sessions. Authenticated `POST /api/capabilities` issues scoped bearer
tokens; requests check expiry/revocation and actor, and calls consume retained
limits. Tokens carry no model credentials or monetary reservations.

[.env.example](../.env.example) lists WorkOS, host-only Sprites credentials,
private-origin hosting, webhook settings and production Phoenix configuration.
Run `mix precommit` for the host and the checks documented in
[workspace_worker](../workspace_worker/README.md) separately. Fixtures test local
contracts and recovery; they do not establish paid inference or production
availability.

Apply the cleanup migrations before serving this code. They retain conversations,
workspaces and native permission decisions while dropping retired domain,
accounting, artifact and hosting registries. Existing definitions containing
removed nodes or parameters require author edits. Historical research and worker
qualification evidence do not impose those removed contracts on new work.
