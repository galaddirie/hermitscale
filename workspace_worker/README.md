# Private Sprite workspace worker

The worker runs the pinned Jido Harness ACP runtime beside a retained checkout.
The host installs the embedded source bundle on the first admitted turn, builds a
Linux release, and installs `@openai/codex@0.162.1` and
`@agentclientprotocol/codex-acp@1.6.2`. Dependencies and provider history remain on
the same Sprite between turns. Published app Sprites run their app service without
installing the coding runtime.

`Hermitscale.Workspaces.Recipe` registers the `hs-worker` Sprite service under the unprivileged `hermitworker` user.
Its private control socket is `/run/hermitscale/worker.sock`. The host reaches it
through authenticated Sprite exec and uint32 length-prefixed JSON. Control is not
an HTTP route and is separate from the app's port 8080. Fleet credentials stay on
the host. A persistent workspace-private control credential and an expiring per-turn inference capability
are delivered through private worker-owned files; the provider runs as `hermitcoder`, which
has no sudo permission. App services run as the separate `hermitapp` user.

A command is journaled and fsynced before acceptance. Its operation ID, payload
digest, generation and deadline bind subsequent inspection, approval, cancellation
and cursor reads. Reconnection inspects the existing operation rather than starting
another model turn. Provider session references are retained and loaded through
Harness's actual Codex ACP continuation interface. A restart marks unfinished work
uncertain and reconciles recorded process groups before permitting a new writer.

Completion, cancellation and deadline expiry close Harness and verify that the
recorded OS process groups have stopped before reporting a terminal operation. An expiring Sprite task hold, created with Req through the local management socket, keeps long turns running until the admitted deadline and is released after cleanup.
The host separately verifies recorded groups and every remaining coder UID process
before releasing its durable lease. An escaped `setsid` child prevents release and
is stopped by the already admitted owner cleanup.
Root-side authority revocation can stop an already admitted worker without granting
new execution authority. Files are retained; deletion is an explicit host operation.

The release reads `WORKSPACE_ID`, `WORKSPACE_CWD`, `WORKSPACE_JOURNAL_PATH`,
`WORKSPACE_ACP_PATH`, `WORKSPACE_CONTROL_SOCKET`, `WORKSPACE_CONTROL_TOKEN_FILE`,
`WORKSPACE_CONTROL_DEADLINE`, `WORKSPACE_PROVIDER_ENV_FILE`, `WORKSPACE_LEASE_FILE`
and `WORKSPACE_PROVIDER_SESSION_FILE`. `WORKSPACE_WORKER_ENABLED=true` starts the
service. The provider environment is replaced rather than inherited and reloads
from the protected file for each new turn, including canonical API-key gateway
configuration and the chosen allowed model. Redaction refreshes with each new
capability. Control command and lease deadlines remain bounded even though the
workspace-private transport credential is retained. New provider starts clear
only the prior result JSON; reconnecting to an accepted operation preserves its
files. Missing or incomplete result JSON remains partial evidence and cannot
claim a successful coding result.

Run `MIX_ENV=core mix precommit` on the host for protocol/journal/control/runtime
fixture tests. The complete Harness dependency requires Elixir 1.19 and Linux
native build tools; `mix precommit` verifies that package on the Sprite. The Linux
release and native Harness process helper were built on a private Sprite during
implementation. A live inference test also requires a selected organization-owned
OpenAI connection and reachable host inference gateway.

## Linux qualification on October 12, 2026

The retained private test Sprite `hs-runtime-build-20261012` supplied Elixir 1.19.2,
OTP 28 and Node 24.18.0 without a manual toolchain installation. The source installer
built the pinned Linux Harness release and native helper. Its physical Node binary
is copied into the trusted runtime path because the platform Node shim needs the
management API that coder/app namespaces hide.

| Check | Observed result |
| --- | --- |
| Managed worker and private control | Unprivileged worker, authenticated exec/socket transport, retained Shell/VFS |
| Deterministic ACP operation | One accepted start, completed operation and independent stop proof |
| Approval | Waiting state, exact response, duplicate response without another delivery, durable events read/acknowledged |
| Cancellation and service restart | Interrupted operations, verified cleanup, no uncertain turn replay |
| Identity boundary | Coder and app identities cannot access the platform management socket |
| Escaped coder child | Independent proof refused release; admitted owner cleanup stopped the child |
| Real Codex and retained follow-up | Pinned Codex/ACP completed two actual Harness turns using the same provider history ID |
| Capability refresh | First request used the original dummy capability; follow-up used the renewed dummy capability |
| HTTP compatibility | Exactly two admitted Responses POSTs, 43,613 and 43,945 bytes; no discovery or WebSocket request |

The real provider test used the local [deterministic Responses fixture](test/support/responses_fixture.py)
and dummy credentials. Synthetic SSE assistant output was observed in the durable
worker journal; both turns independently proved termination. Final measured worker
activity was 11,218 ms and 10,920 ms. The fixture enforces the host's text input,
request size, opaque-history and bounded function/custom tool rules, including
namespace wrappers with only those client tools. Paid model inference and a
production deployment were not exercised.

Run `python3 -m unittest discover -s priv/workspace_launchers` from the repository
root for actual OS Git/source/result-boundary checks. Both the host worker core precommit and the full Linux worker precommit under
`hermitworker` passed 17 tests; the launcher/source/publication suite passed 22.
The Docker image was inspected and its wrapper/policy tested; a Docker image build
was not executed because the local daemon was unavailable.

## Docker image

Build with the repository root as the context:

```sh
docker build -f workspace_worker/Dockerfile -t hermitscale-workspace-worker .
```

The image pins Elixir 1.19.6 / OTP 28, Codex 0.162.1, and Codex ACP 1.6.2. It
includes the root-owned sandbox launcher and provider wrapper, validates the
worker-only `NOSETENV` sudo policy, and starts the release as `hermitworker`.
Control defaults to disabled. The configured runtime must expose the Sprite
management socket at `/.sprite/api.sock` for real task holds and permit the
launcher's mount namespace isolation and sudo identity transition. A standard
Docker runtime does not provide this platform contract; rejected isolation or an
unavailable task hold prevents provider execution.

The image supplies the fixed control paths listed above. Install worker-owned
mode `0600` files `token`, `provider-env.json`, and `lease.json` under the private
`/var/lib/hermitscale/control` directory, set `WORKSPACE_ID` and
`WORKSPACE_CONTROL_DEADLINE`, then set `WORKSPACE_WORKER_ENABLED=true`.
The provider JSON contains the gateway `OPENAI_BASE_URL`, expiring `OPENAI_API_KEY`,
and `HERMITSCALE_MODEL`, with `HOME=/home/hermitcoder`,
`CODEX_HOME=/workspace/.codex`, and
`PATH=/opt/hermitscale/bin:/opt/hermitscale/provider/node_modules/.bin:/usr/local/bin:/usr/bin:/bin`.
Retain `/workspace` and `/var/lib/hermitscale/control` across starts, including
lease/group evidence and provider history. Mounted directories must preserve the
image's private modes and ownership: worker UID 10001, coder UID 10002, app UID
10003; `.codex` is coder-owned mode `0700` and app data directories are app-owned
mode `2770`.
