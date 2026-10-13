# Hermitscale

Hermitscale combines durable coding conversations, Runic workflows, and small
published apps in a Phoenix application. Coding runs through a managed Sprite
worker with Jido Harness and Codex. Conversations, native permission prompts, workflow waits,
publication intent, app releases, and usage remain in Postgres when compute sleeps.

## Run locally

The host requires Elixir 1.18+, Erlang/OTP 27+, and PostgreSQL. Copy [.env.example](.env.example) to
`.env` and set your WorkOS, Sprite, inference gateway, model, and rate configuration.
Development reads `.env` from `config/runtime.exs`.

```sh
mix setup
mix phx.server
```

Open [localhost:4000](http://localhost:4000), sign in, and use `/agents` for
conversations and `/apps` for app build, preview, release, and recovery.
Use `/workflows` to edit definitions, validate them, and inspect retained runs. Default
seeding creates no tenant records. Optional `DEV_SEED_ORG_ID` and
`DEV_SEED_USER_ID` select an existing development actor whose current directory
membership authorizes the example workflows.

The inference gateway must be reachable from a Sprite. Set
`INFERENCE_GATEWAY_URL` to the externally reachable `/inference/v1` URL. Model
access uses an organization-owned OpenAI connection through WorkOS Pipes. Set
`CODING_ALLOWED_MODELS`, the configured input/output rates in micro-dollars per
million tokens, and a `CODING_RATE_VERSION` for the usage ledger.

`SPRITES_API_KEY` configures the server's private management adapter. The first
turn installs the pinned worker/provider recipe, initializes the checkout, and
starts the managed private control service. Subsequent turns reuse the retained
workspace and provider conversation. Recipes are `codex-v1` for repositories and
`python-sqlite-v1` for the included small-app profile.

## Identity and permissions

WorkOS AuthKit owns users, organizations, memberships, and authentication. The
configured `Hermitscale.Auth.Provider` can be replaced without adding local user
or session tables. Browser and LiveView requests carry the verified organization
scope; jobs revalidate the recorded actor before effects. WorkOS Pipes supplies
organization-owned provider accounts separately from browser authentication.

Configure the role permissions used by your members:

| Area | Permissions |
| --- | --- |
| Conversations | `agents:read`, `agents:run`, `agents:publish` |
| Workspaces | `workspaces:read`, `workspaces:write` |
| Apps | `apps:read`, `apps:write`, `apps:deploy` |
| Workflows | `workflows:run`, `workflows:edit`, `workflows:activate` |
| Provider setup | `connections:manage` |

Conversations are private to their initiator. Closing a browser retains admitted
work; archive retains files and history. Cancellation records intent and waits
for independently verified writer termination before releasing its fenced lease.
Stored history, artifacts, app metadata, and diagnostic logs can be read without
attaching to a Sprite.

Recorded changes include diffs and private exports of new files. Conversations
show paths, checksums and scoped download links. Failed and interrupted turns
retain available change evidence and selected check outcomes. Usage
records deduplicate measured model tokens/cost, compute milliseconds, and logical
artifact storage bytes. Compute and storage measurements are currently unpriced.

## Coding workflows

Existing pure graphs use Runic's native Runner. External catalog nodes use its
supported `prepare_for_dispatch/2` and `apply_runnable/2` lifecycle with durable
activation reservations, native event checkpoints, and bounded Oban coordination.
Waiting produces no successful output and prevents run completion. Terminal
acceptance, native events, and the consumed reservation commit together.

Keyed workflow creation binds the author's raw intent before selecting provider
accounts. A retry returns the retained graph; a changed payload with that key is
rejected. Creating or transitioning a graph to active requires activation permission.
The admitted graph definition is immutable for a run. Resuming uses that snapshot;
subsequent editor changes apply to new runs. Definition fingerprints normalize
scheduler regex source/options and reject incompatible callback identities or
histories. Mapped identical inputs retain independent occurrence IDs and lineage.

The durable agent/app catalog includes `agents.codex.run`, `agents.publish_branch`,
`apps.preview.create`, `apps.deploy` and `apps.logs.read`. These operations wait
for results from their owning contexts. GitHub, Linear and other provider nodes
remain independently composable integrations with their ordinary effect/retry
contracts. A ticket triggering an app or repository edit is a user-authored
workflow, not a built-in support product or a mandatory PR/reply pipeline.

Publication binds an explicit manifest to verified patch evidence, revalidates
`agents:publish`, and verifies the remote branch. Deployment and recovery use
current actor app permissions and exact release/backup inputs. No separate
reviewer role or review record is required for these explicit requests.

See [node authoring](docs/node-authoring-kit.md),
[integrations](docs/integrations.md), and
[implementation details and validation](docs/agent-apps-implementation.md).

## Apps and serving

Apps own stable environments and immutable source bundles. Preview runs in the
editing workspace; a deployment activates a verified release in a separate
serving workspace. SQLite, uploads, and other mutable data live outside versioned
releases. Code rollback reuses current data; explicit backup restoration is separate.
Scheduled backups retain integrity-checked exports.

The included `python-sqlite-v1` starter is blank and SQLite-capable. It initializes
no sample business tables or API. New sessions clone the selected repository or
initialize this starter; release source artifacts do not define a separate
investigation-source conversation contract.

Configure `APP_GATEWAY_HOST` on a different registrable domain from the control
plane, for example `apps.example.net` with `PHX_HOST=control.example.com`. Route
its wildcard to the Phoenix endpoint with TLS. Generated preview grants use separate origins
and expire independently of workspace storage. Opening a recorded preview creates
a private grant after rechecking scope. Public serving is an explicit actor
choice tied to the expected active verified deployment. The app gateway supports HTTP and
WebSocket proxying without forwarding the control-plane cookie.

## Product tools

`/mcp` uses ExMCP 1.6 for HTTP transport, protocol negotiation, stateless
`server/discover`, and legacy `initialize` sessions. Expiring bearer capabilities
are issued at authenticated `POST /api/capabilities` and revalidated on every
request. Sessions are bound to the capability and organization; tool discovery
and execution retain its action, resource, call, and current actor limits. Keyed creation, continuation, preview, publication and deployment requests
require stable `operation_key` values. Repeating a keyed run start returns the
same admitted run; a changed payload with that key is rejected.

[The HTTP mount](lib/hermitscale_web/mcp.ex) handles bearer authentication;
[the ExMCP handler](lib/hermitscale/mcp/server.ex) delegates product operations
to the public contexts. ExMCP owns JSON/SSE negotiation, so this route uses its
own token-authenticated scope outside the browser and JSON-only API pipelines.

Product tools cover workflow definitions/runs, conversations, app builds/previews/
logs and deployment requests. They use the same authorization and idempotency
rules as the browser and workflow contexts.

Native coding-runtime permission prompts belong to the pending agent turn. The
executing actor answers with current conversation access and `agents:run`
authority. Ordinary chat can produce text; a nonempty `result_schema` opts into
JSON-result validation. Caller-selected `verification_commands` opt into recorded
checks. Neither a fixed business-result schema nor a repository test command is
imposed on every turn.

## Verification and releases

```sh
mix precommit
```

The worker is a separate Elixir 1.19 project. From `workspace_worker`,
`MIX_ENV=core mix precommit` exercises the journal, protocol, fencing, cancellation,
and Harness adapter fixtures under the host toolchain. Production Harness builds
use the pinned Linux worker recipe; see [worker packaging](workspace_worker/README.md).
The host and worker contract tests use deterministic provider/transport fixtures.
An actual external service run requires configured organization connections and
credentials; fixture results do not assert a paid Codex or live Sprite deployment.

For a Phoenix release, set `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`,
`PHX_SERVER=true`, and the configuration in `.env.example`; run migrations before
serving. `mix.lock` pins Runic, Jido, Shell, VFS, and the Sprites SDK. Revalidate
collection/replay and worker contracts when advancing those revisions.

The [scope cleanup migration](priv/repo/migrations/20261013132941_remove_example_workflow_domains.exs)
preserves native turn permission decisions, then deletes retired support, review
and delivery records/tables and revokes their tool capabilities. Definitions
using the removed example-domain node IDs must be edited before running again.
See [current design](docs/agent-apps-design.md) and
[implementation contracts](docs/agent-apps-implementation.md).
