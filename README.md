# Hermitscale

Hermitscale combines durable coding conversations, Runic workflows, and small
published apps in a Phoenix application. Coding runs through a managed Sprite
worker with Jido Harness and Codex. Conversations, reviews, workflow waits,
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
conversations, `/apps` for app build, preview, release, and recovery, and
`/reviews` for action details, recorded patch evidence, and approval decisions.
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
| Reviews | `reviews:read`, `reviews:request`, `reviews:decide` |
| Workflows | `workflows:run`, `workflows:edit`, `workflows:activate` |
| Support | `support:investigate`, `support:reply` |
| Provider setup | `connections:manage` |

Conversations are private to their initiator. Closing a browser retains admitted
work; archive retains files and history. Cancellation records intent and waits
for independently verified writer termination before releasing its fenced lease.
Stored history, artifacts, app metadata, and diagnostic logs can be read without
attaching to a Sprite.

Recorded changes include diffs and private exports of new files. Reviews show
their paths and checksums with scoped download links. Failed and interrupted
turns retain available change evidence and the actual check outcomes. Usage
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

The catalog includes `agents.codex.run`, `agents.publish_branch`,
`apps.preview.create`, `apps.deploy`, `apps.logs.read`, `reviews.request`,
`support.investigate`, and `support.reply`. GitHub PR creation and Linear comment
creation retain effect intent and reconcile lost responses against provider
markers. Publication binds an explicit manifest to the verified patch snapshot,
then verifies the remote branch. The PR step checks that published branch revision
again. Publication, deployment, and support reply request an exact review when the
workflow did not provide an approved review ID.

See [node authoring](docs/node-authoring-kit.md),
[integrations](docs/integrations.md), and
[implementation details and validation](docs/agent-apps-implementation.md).

## Apps and serving

Apps own stable environments and immutable source bundles. Preview runs in the
editing workspace; a deployment activates a verified release in a separate
serving workspace. SQLite, uploads, and other mutable data live outside versioned
releases. Code rollback reuses current data; approved data recovery is separate.
Scheduled backups retain integrity-checked exports.

Repository and app builds can start from an authorized checksummed source bundle.
The host binds the bundle to the admitted conversation and verifies its digest
before workspace initialization; release records retain their source identity.

Configure `APP_GATEWAY_HOST` on a different registrable domain from the control
plane, for example `apps.example.net` with `PHX_HOST=control.example.com`. Route
its wildcard to the Phoenix endpoint with TLS. Generated preview grants use separate origins
and expire independently of workspace storage. Opening a recorded preview creates
a private grant after rechecking scope. Public serving is an explicit reviewed
choice tied to the active verified deployment. The app gateway supports HTTP and
WebSocket proxying without forwarding the control-plane cookie.

## Product tools and support

`/mcp` uses ExMCP 1.6 for HTTP transport, protocol negotiation, stateless
`server/discover`, and legacy `initialize` sessions. Expiring bearer capabilities
are issued at authenticated `POST /api/capabilities` and revalidated on every
request. Sessions are bound to the capability and organization; tool discovery
and execution retain its action, resource, call, and current actor limits. Mutations
require stable `operation_key` values. Repeating a keyed run start returns the
same admitted run; a changed payload with that key is rejected.

[The HTTP mount](lib/hermitscale_web/mcp.ex) handles bearer authentication;
[the ExMCP handler](lib/hermitscale/mcp/server.ex) delegates product operations
to the public contexts. ExMCP owns JSON/SSE negotiation, so this route uses its
own token-authenticated scope outside the browser and JSON-only API pipelines.

Product tools cover workflows, runs, conversations, reviews, apps, previews,
artifacts/releases, and support. Linear support subscriptions bind a trusted app
and environment to a ticket prefix and an explicit coding connection set.
Investigation starts from the recorded deployed
revision. A reviewed reply distinguishes explanation, workaround, proposed fix,
and verified deployment; deployment claims require current release and defect
verification evidence.

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
