# Agents and Apps implementation

October 12, 2026. Implements [the design](agent-apps-design.md) through the
existing public contexts, Runic engine, Jido coordination, and retained Sprite
worker. Configuration failures produce explicit operation outcomes; runtime work
is dispatched through the concrete adapter.

## Product paths

| Path | Owner and durable behavior |
| --- | --- |
| Browser sign-in | AuthKit code exchange, expiring OAuth state, opaque encrypted provider session, current organization membership on HTTP and LiveView reconnect |
| Coding conversation | `Agents` owns idempotent sessions, immutable turn admission, selected connections, budgets, ordered history, provider continuation, approval/input/cancel intent, verified result artifacts |
| Workspace execution | `Workspaces` allocates retained Sprites, installs the pinned recipe, enforces an exclusive fencing generation/deadline, reaches a private worker socket, verifies termination before lease release |
| Workflow continuation | `Workflows` stores the admitted definition, exact activation reservation, committed native Runic events, terminal evidence and notification work; pending operations block completion |
| Branch and PR publication | Manifest and patch snapshot bind review to actual changes; publication reconciles commit/push and verifies the remote revision; GitHub PR and Linear comment deliveries retain known/uncertain outcomes |
| App build and preview | App build conversations retain editing files; previews are explicitly started and verified, and opening a recorded preview creates an expiring isolated-origin access grant |
| App release | Immutable checksummed source artifact, configuration digest, exact review and active-release comparison precede activation in a distinct persistent serving environment |
| SQLite recovery | Published data lives outside releases; verified backups, code rollback and explicitly approved data recovery have separate records and operations |
| Support | Trusted subscription/environment mapping and coding connection selection anchor investigation to the deployed revision; ticket content remains evidence, and customer replies require exact review and provider delivery reconciliation |
| Product MCP | ExMCP HTTP transport and protocol negotiation expose public context tools through expiring action/resource capabilities, current actor validation, call limits and mutation idempotency |
| Usage | Model tokens/cost, compute milliseconds, and logical workspace file bytes have independent deduplicated records; compute/storage are unpriced, while model reservations, configured rate version and uncertain responses remain visible |

Browser surfaces are `/agents`, `/agents/:id`, `/apps`, `/apps/:id`,
`/apps/:id/build`, `/apps/:id/deployments/:deployment_id`, `/reviews`, and
`/reviews/:id`, `/workflows`, and `/workflows/:id`. They use the existing
browser authentication pipeline and one authenticated LiveView session. Private
artifact downloads and capability issuance use the same scope boundary. App
traffic uses the separate gateway host, and private worker control uses
server-authenticated Sprite transport.

`/mcp` is forwarded to [the bearer-authenticated HTTP mount](../lib/hermitscale_web/mcp.ex),
with [the ExMCP handler](../lib/hermitscale/mcp/server.ex) supplying the scoped product
catalog. ExMCP owns JSON/SSE content negotiation, stateless `server/discover`, and
legacy `initialize` sessions. Each request revalidates its bearer; legacy sessions
are bound to its capability ID and organization. Tool calls separately enforce
action/resource authority, an atomic retained call budget, current permissions
and public context rules. The route uses its own scope outside the
browser and JSON-only API pipelines.

Server callbacks have a bounded five-minute deadline (`300_000` milliseconds)
for synchronous preview setup. Clients choose their request timeouts separately;
a shorter client timeout can expire before the server callback finishes.

## Runic acceptance contract

The locked Runic revision is `6e6373832c00aa9ec5d19faeae945b61e2db50b1`.
The external driver uses `Workflow.prepare_for_dispatch/2` with an exclusion
predicate for reserved activations, and `Workflow.apply_runnable/2` for terminal
acceptance. It uses native SingleOutput completion so output facts retain item
metadata, native collection tracking, input occurrence identity and hooks.
No pending marker is returned as successful node output.

Run admission, its definition/initial native events, and its dispatch job commit
atomically. An external reservation includes definition fingerprint, component,
activation and input identities, mapped lineage, resolved non-secret request,
owner resource and deadline. Owner dispatch runs outside that transaction.
Terminal outcome and notification job commit first. Native accepted events and
the consumed reservation then share a transaction. Repeated or restarted handoff
cannot publish another occurrence; conflicting terminal payloads are rejected.

Graphs retain their admitted definition when an author edits the current graph.
Scheduler fingerprints use regex source/options, preserving independent compiler
replay across fresh PCRE resources. Pure graphs retain native Runner execution;
keyed product-tool admission uses the durable driver so a retry cannot repeat
work or strand an unstarted run after a crash.

Graph creation keys belong to the organization and author. The retained digest
binds the raw, cast-valid authoring intent before account selection, allowing a
retry to return its graph even when provider setup subsequently changes. A
different payload with that key is rejected. Draft-to-active transitions require
the backend activation permission, and stored run listings are scoped and bounded.

External nodes are `agents.codex.run`, `agents.publish_branch`,
`apps.preview.create`, `apps.deploy`, `apps.logs.read`, `reviews.request`,
`support.investigate`, and `support.reply`. `github.pull_requests.create` and
`linear.comments.create` also use retained delivery ownership. Unknown provider
outcomes remain uncertain and are reconciled by exact marker/target reads before
another mutation could be considered.

## Runtime composition

| Component | Selected implementation |
| --- | --- |
| Phoenix host | Elixir 1.18+, Erlang/OTP 27+, Postgres, Oban and Phoenix PubSub |
| Coordination | Jido 2.4.0 AgentServer/actions over committed product records |
| Shell | Git revision `3c9af797d1f2c852e2b182e77509fafc5b51f86b` |
| VFS | Hex 1.0.1 with current lease/path checks in the public workspace boundary |
| Sprites SDK | Git revision `c59c9358787ece90fb83b0631dde57f54a173753` plus host-only management credentials |
| Product MCP transport | ExMCP 1.6.0; Cowlib 2.20 overrides the Sprites SDK's OTP 26 compatibility pin |
| Worker protocol | Shared v1 validation schemas, command identity/digest, framed private socket, retained acceptance/event journal |
| Coding runtime | Harness revision `2cea7100174de3aae3ece358612f2405a175217f`, Codex CLI `0.162.1`, Codex ACP `1.6.2` |
| App recipe | `python-sqlite-v1`, immutable release code and separate persistent data paths |
| Model transport | Fixed OpenAI Responses upstream through a host inference gateway and short-lived, per-turn budget capability; bounded function/custom client tools and validated namespace wrappers |

The installer packages the source recipe and starts the private worker as a managed
Sprite service. Repository code runs under its own Unix identity. Fenced worker
commands, confined file access, bounded diagnostics and independent process
termination evidence keep callback/runtime resources out of saved workflow facts.
Provider conversation IDs are retained for follow-up turns; restarting the worker
reconciles accepted work rather than blindly replaying paid turns.

Initial repository/app source may be an authorized `source_bundle` artifact. Its
owner and checksum bind the immutable session admission, and the remote installer
verifies the bundle before initializing the workspace. Results retain bounded
diff, file metadata and checks. New-file contents are private `workspace_file`
artifacts named by the recorded snapshot's exports. Conversation and review
screens provide scoped path/checksum download links, including repeated files
with identical bytes. Each new accepted provider start clears the prior result JSON through a nofollow
path; reconnecting never clears an existing operation. Missing, unsafe, malformed
or oversized JSON has explicit invalid evidence flags and bounded diagnostics.
Failed/interrupted turns retain available partial evidence;
an unsuccessful check remains unsuccessful in the UI. Review-only access is
limited to the exact snapshot and its same-session exported files.

Publication retains a verified remote result before writer cleanup. A restart can
finish that cleanup without another publication command. Completed keyed retries
return their recorded outcome after current actor and private-session checks,
including when the original review has expired. Known refusals retain a failed
outcome after confirmed termination; uncertain responses remain uncertain.
Deadline and exhausted-attempt recovery stop the admitted writer and permit only
marker/ref reads. Publication uses an isolated bare Git store for network effects,
with source hooks, filters and Git configuration excluded from credentialed work.
Follow-up coding uses the latest verified publication baseline without changing
the session's original admission identity. A separately retained local-commit
receipt may advance that private baseline after confirmed writer termination;
remote publication still remains uncertain until its ref is independently verified.

## Configuration

[The environment sample](../.env.example) and [README](../README.md) describe
WorkOS/Pipes connections, Sprite management, externally reachable inference URL,
allowed model IDs and configured rates, the separate wildcard app gateway, signed
webhooks and production database/server settings. Provider roles grant the actual
product permissions used by each context. Missing live service configuration is
an actionable request failure.

## Verification evidence

The automated evidence includes:

- [External workflow tests](../test/hermitscale/workflows/external_operations_test.exs): coding wait to manifest publication to mocked GitHub PR and Linear notification, absence of premature output, duplicate completion/restart, identical mapped inputs, edited graph snapshots, failed turns, real owner admission retry and real human-review continuation.
- [Delivery tests](../test/hermitscale/integrations/deliveries_test.exs): retained success, payload-key conflicts, response loss, marker reconciliation and no duplicate POST after an unresolved remote outcome.
- [Product tool tests](../test/hermitscale/product_tools_test.exs): public compiler/context calls, organization permissions and repeated keyed run admission.
- [Graph admission tests](../test/hermitscale/workflows/graph_admission_test.exs): raw-intent creation idempotency across provider changes, actor and tenant identity, protected activation and bounded stored run queries.
- [Publication tests](../test/hermitscale/agents/publications_test.exs): retained patch snapshots, exact reviewed manifests and branches, changed-candidate denial, artifact ownership, current publisher authority, result/lease crash recovery, completed-key retries, deadline reads, revocation/exhausted-attempt cleanup and separate uncertain local-commit receipts.
- [Support tests](../test/hermitscale/support/end_to_end_test.exs): trusted serving revision and coding selection, retained investigation/turn identity, exact reviewed Linear reply, no repeated mutation and denied tenant/prefix/deployment claims.
- [Review tests](../test/hermitscale/reviews_test.exs): exact action/digest/policy, expiry, approver eligibility, current membership revocation, idempotent decisions and denial of arbitrary-review or cross-session export self-grants.
- [Review browser tests](../test/hermitscale_web/live/reviews_live_test.exs): authenticated inbox, displayed action and patch evidence, private exported file links, approval and rejection, expiry, eligibility and authority revocation.
- [Capability and inference tests](../test/hermitscale/integrations/execution_access_test.exs): hashed tokens, expiry/revocation, scope limits, locked reservations, model and output-token admission, actual usage settlement and missing/negative usage evidence.
- [MCP HTTP tests](../test/hermitscale_web/mcp_test.exs): ExMCP discovery and legacy sessions, content negotiation and protocol errors, bearer revalidation, scoped tools/resources, organization boundaries, call exhaustion, and rejected batches/tool notifications.
- [MCP client interoperability tests](../test/hermitscale_web/mcp_client_test.exs): ExMCP Client connects through Bandit to the Phoenix endpoint in modern and legacy modes, lists only selected tools, reads stored resources, and observes resource/call limits.
- [MCP callback deadline test](../test/hermitscale_web/mcp_deadline_test.exs): the authenticated HTTP mount completes a delayed callback beyond ExMCP's default ten-second deadline.
- App, conversation and workspace tests cover owner context behavior and authenticated LiveView flows. [Worker tests](../workspace_worker/test/) cover durable acceptance, fencing, journal restart/recovery, cancellation, bounded replay, private control and Harness adapter contracts.

Run `mix precommit` for the host and `MIX_ENV=core mix precommit` in
`workspace_worker`. Provider and transport tests use deterministic fixtures.
These demonstrate implemented contracts and recovery behavior; they do not claim
a live paid Codex turn or production Sprite deployment without executing those
services with configured credentials.


### Executed private Linux qualification

On October 12, 2026, the retained test Sprite `hs-runtime-build-20261012` built the
pinned Linux Harness release/native helper using its preinstalled Elixir 1.19.2,
OTP 28 and Node 24.18.0. The managed worker ran as `hermitworker`; coder and app
profiles used separate identities and could not open the platform management
socket. Authenticated private control, Shell/VFS, deterministic ACP start,
approval/duplicate response, event read/ack, cancellation and service restart all
passed. Restart recovery did not start a second uncertain model turn. A deliberately
escaped coder child prevented writer release until owner cleanup stopped it.

Actual installed Codex 0.162.1 and ACP 1.6.2 then completed a turn and a retained
follow-up through Harness against a local deterministic Responses/SSE server with
dummy credentials. Both used the same real provider history ID and independently
proved termination. The follow-up used the renewed dummy capability. Only two
Responses POSTs were required (43,613 and 43,945 bytes), with admitted text input,
function/namespace client tools and no opaque provider history; no model discovery
or WebSocket endpoint was needed. The known synthetic assistant response appeared
in both durable journals. Measured operation activity was 11,218 ms and 10,920 ms.
These are provider transport checks; no paid model inference, production app
publication or production cloud deployment is claimed.

The focused workspace/publication suite passed 34 tests. Worker core precommit
and full Linux worker precommit under the unprivileged worker each passed 17 tests; the actual OS launcher, source seed and isolated Git publication
suite passed 22, including missing/partial result capture, nofollow result cleanup,
malicious Git configuration/filter denial, large diff parity, retained source
imports and lost push-response reconciliation. See the [worker evidence and
packaging instructions](../workspace_worker/README.md).

Final project checks passed: host `mix precommit` completed 604 tests with no
failures, and `mix assets.build` built both bundles. The separate worker's core
precommit and full Linux precommit each completed 17 tests with no failures; the
Linux run used the actual pinned Harness/native application as `hermitworker`.
