# Hermitscale

Hermitscale is a Phoenix application for coding conversations, user-authored
Runic workflows and apps running on retained Fly.io Sprites. Codex runs through
Harness in a private workspace worker. Postgres retains conversations, turns,
events and Runic execution history; Oban dispatches admitted coding turns.

## Run locally

The host requires Elixir 1.18+, Erlang/OTP 27+ and PostgreSQL. Copy
[.env.example](.env.example) to `.env` and configure WorkOS and Sprites.
Development reads `.env` from `config/runtime.exs`.

```sh
mix setup
mix phx.server
```

Open [localhost:4000](http://localhost:4000) and sign in. `/agents` contains
conversations, `/apps` contains app conversations and service controls, and
`/workflows` contains definitions and stored runs. Default seeding creates no
tenant records. Optional `DEV_SEED_ORG_ID` and `DEV_SEED_USER_ID` identify an
existing authorized development actor for example graphs.

`SPRITES_API_KEY` stays on the host. Select an organization-owned OpenAI account
through WorkOS Pipes for coding. The worker receives its authorized API key and
uses the provider's normal authentication. There is no Hermitscale inference
proxy, model-rate configuration or usage ledger. A GitHub connection supplies
credentials for private checkout and explicit publication.

The first turn installs the pinned worker/provider runtime and initializes the
selected repository, or an empty Git workspace for a new app. A repository's
starting commit is optional; omitting it uses the default checkout. Follow-ups
retain files, dependencies and provider conversation history.

## Identity and permissions

WorkOS owns identity, organizations, membership and browser authentication. Pipes
supplies provider connections. Context calls use verified organization scope;
jobs revalidate the recorded actor before execution.

| Area | Permissions |
| --- | --- |
| Conversations | `agents:read`, `agents:run`, `agents:publish` |
| Workspaces | `workspaces:read`, `workspaces:write` |
| Apps | `apps:read`, `apps:write`, `apps:deploy` |
| Workflows | `workflows:run`, `workflows:edit`, `workflows:activate` |
| Provider setup | `connections:manage` |

Sessions are private to their initiator. Closing the browser, completing a turn
or archiving a session retains its files. Cancellation records intent and releases
the writer only after termination is verified. Native permission prompts belong
to the pending turn; its executing actor answers with current `agents:run`
authority. There is no separate reviewer role or review inbox.

Ordinary chat produces text and stored events. A nonempty `result_schema` opts
into a bounded JSON-result read and validation. Explicit `verification_commands`
request checks for that turn. No test suite, file export or artifact snapshot is
required to complete a conversation.

## Workflows and Git

The agent/app nodes are `agents.codex.run`, `agents.publish_branch`,
`apps.preview.create`, `apps.publish` and `apps.logs.read`. Coding nodes await the
existing agent turn; branch publication and native service actions return their actual results.
Existing GitHub, Linear and other provider nodes remain independently composable.

A ticket triggering a repository edit or app update is an example authored graph.
It is not a built-in support domain or a mandatory PR/reply pipeline. Provider
nodes keep their ordinary effect and retry contracts.

Branch publication accepts `branch`, `message` and `operation_key`, checks current
`agents:publish` authority and acquires the workspace writer lease. Ordinary Git
commit/push and remote branch verification produce repository/branch/commit
results. Keyed request and result history reject changed intent and retain known
success; no manifest artifact or separate publication registry is required.

Run admission retains a definition snapshot and input occurrence identity. Runic
owns node execution, retries and accepted event history. Coding retries reuse the
same keyed session and turn for their input occurrence. Repeated keyed graph/run
admission rejects changed intent; editor changes apply to future runs.
Workflows start and resume immediately in native Runic. Initial input events and
accepted history remain stored. Automatic workflow restart recovery is deferred.
`Agents.ReconcileWorker` owns coding-turn dispatch on the `agents` Oban queue.

See [node authoring](docs/node-authoring-kit.md), [integrations](docs/integrations.md)
and [current design](docs/agent-apps-design.md).

## Apps

An app records its owner, coding conversation, chosen start command/port, current
Git revision when available and native Sprite service URL/status. Build with ordinary chat, then
explicitly start a private preview or publish the service. The application decides
its framework, database, build steps and checks.

Apps run in the retained coding Sprite. Editing that workspace can change its
running app; this is not an immutable-release hosting system. There is no required
Python/SQLite starter, deployment registry, automatic backup/migration or platform
data-recovery policy. Data maintenance belongs to explicit workload operations.

Public publication enables the native Sprite URL. Private HTTP access uses the
small authenticated broker on a different registrable domain from the control
plane; configure `APP_GATEWAY_HOST` and route it with TLS. Provider credentials
stay server-side. Service logs are deliberately fetched from Sprites rather than
mirrored into a separate app-log table.

## Product tools and operation

`/mcp` uses ExMCP for JSON/SSE negotiation and modern/legacy sessions. Authenticated
`POST /api/capabilities` issues expiring bearer tokens scoped to resources and
actions. Every request revalidates the token and actor; tool calls consume a
retained call limit. Tools cover workflows/runs, conversations and app
creation/build/preview/publication/logs through the same public contexts.

Run `mix precommit` for the host. The separate worker has its own documented
checks and pinned Linux packaging; see [worker instructions](workspace_worker/README.md)
and [operations](docs/agent-apps-operations.md). Fixture checks do not establish
paid model execution or production service availability.

For a Phoenix release, configure `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`,
`PHX_SERVER=true` and `.env.example`, then run migrations before serving. Cleanup
migrations remove retired example-domain, artifact, billing and hosting records
while retaining conversations, native permissions and Sprite files. Definitions
using removed nodes or fields need author edits.
