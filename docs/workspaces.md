# Workspaces

`Hermitscale.Workspaces` manages organization-owned workspaces backed by
[Fly Sprites](https://docs.fly.io/sprites): persistent Linux microVMs that sleep
when idle and wake on use. See the [design](agent-apps-design.md) for how
workspaces fit into the product.

Every function takes a verified `Hermitscale.Accounts.Scope` first and requires
the `workflows:run` permission. Members can use every workspace in their
organization. Workspaces in other organizations return `{:error, :not_found}`.

## Configuration

Set `SPRITES_API_KEY` (or `SPRITE_TOKEN`) to a server-side Sprites token. Optional
`SPRITES_API_BASE_URL` defaults to `https://api.sprites.dev`. Remote operations
raise if no token is configured.

REST calls use Req. Commands use the [official Elixir SDK](https://github.com/superfly/sprites-ex)
WebSocket transport. Non-2xx responses return `{:error, :not_found}`,
`{:error, :conflict}`, or `{:error, {:http_error, status, body}}`.

## Lifecycle

```elixir
{:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Development"})
{:ok, workspaces} = Workspaces.list_workspaces(scope)
{:ok, %{"status" => status}} = Workspaces.get_sprite(scope, workspace.id)
{:ok, _deleted} = Workspaces.delete_workspace(scope, workspace.id)
```

Creation validates the attributes, creates the Sprite, then inserts the record.
If the provider fails, nothing is stored. If the provider created the Sprite but
its response was lost, that `hs-` prefixed Sprite is orphaned.

Deletion destroys the Sprite (a missing Sprite counts as deleted), then the
record. Sleep state (`cold`, `warm`, `running`) is read live with `get_sprite/2`
and never stored. Any operation wakes the Sprite.

## Commands

```elixir
{:ok, %{stdout: stdout, stderr: stderr, exit_code: code}} =
  Workspaces.execute(scope, workspace.id, "bash", ["-lc", "pwd"], dir: "/home/sprite")

{:ok, command} = Workspaces.spawn(scope, workspace.id, "bash", [], stdin: true, session_info: true)
Sprites.write(command, "pwd\n")
```

`spawn` sends `{:stdout | :stderr, %{ref: ref}, bytes}`, `{:exit, %{ref: ref}, code}`,
`{:error, %{ref: ref}, reason}`, and `{:session_info, %{ref: ref}, id}` to the caller
or `:owner`. The local WebSocket closes when the owner exits. The remote command
may keep running; use `list_sessions/2` and `kill_session/4` to manage it.

## Files, checkpoints, services, and URLs

```elixir
{:ok, _} = Workspaces.write_file(scope, workspace.id, "/tmp/a.txt", "hello", mkdir: true)
{:ok, bytes} = Workspaces.read_file(scope, workspace.id, "/tmp/a.txt")
{:ok, listing} = Workspaces.list_files(scope, workspace.id, "/tmp")
:ok = Workspaces.delete_file(scope, workspace.id, "/tmp/a.txt")

{:ok, progress} = Workspaces.create_checkpoint(scope, workspace.id, comment: "before")
{:ok, checkpoints} = Workspaces.list_checkpoints(scope, workspace.id)
{:ok, progress} = Workspaces.restore_checkpoint(scope, workspace.id, "v1")

{:ok, _} =
  Workspaces.put_service(scope, workspace.id, "web", %{
    cmd: "python3",
    args: ["-m", "http.server", "8080"],
    http_port: 8080
  })

{:ok, _} = Workspaces.update_url_settings(scope, workspace.id, %{auth: "public"})
```

Sprite URLs start private (`auth: "sprite"`). Restore replaces the whole
filesystem. Service and checkpoint attributes follow the
[Sprites API](https://docs.fly.io/sprites).

## Provider credentials

Provider credentials never enter a Sprite
([ADR-0001](adr/0001-broker-workspace-credentials.md)). Code in a workspace calls
the credential broker (`Hermitscale.CredentialBroker`), which vends the
organization's WorkOS Pipes credential server-side and forwards the request.

An admin (`connections:manage`) grants a connected account to a workspace with
rules. A rule is `"<METHOD> <path>"`. The method is an HTTP method, `FETCH` or
`PUSH` for Git, or `*`. The path is exact, or a prefix when it ends in `*`.

```elixir
{:ok, _grant} =
  CredentialBroker.put_grant(scope, workspace, %{
    provider: "github",
    account_id: "data_123",
    rules: ["GET /repos/acme/*", "POST /repos/acme/web/issues", "FETCH /acme/web", "PUSH /acme/web"]
  })
```

A member then issues a short-lived broker token (at most 24 hours) and passes it
to a command's environment. Don't write the token to the Sprite's disk: files
persist in checkpoints.

```elixir
{:ok, secret, token} = CredentialBroker.issue_token(scope, workspace, ttl: 3600)

Workspaces.execute(scope, workspace, "bash", ["-lc", script],
  env: Map.to_list(CredentialBroker.env(secret))
)

:ok = CredentialBroker.revoke_token(scope, token.id)
```

Inside the Sprite:

```bash
# Provider APIs: https://<broker>/api/<provider>/<provider path>
curl -H "Authorization: Bearer $HERMITSCALE_BROKER_TOKEN" \
  "$HERMITSCALE_BROKER_URL/api/github/repos/acme/web/issues"

# Git smart HTTP. The token is supplied per command, so it isn't stored in .git/config.
git -c credential.helper='!f() { echo username=x; echo "password=$HERMITSCALE_BROKER_TOKEN"; }; f' \
  clone "$HERMITSCALE_BROKER_URL/git/github/acme/web.git"
```

Every request re-checks the token, the grant, and the rule, then the acting
member's membership and the account's state. Errors are JSON:
`401 unauthorized`, `403` (`not_granted`, `endpoint_not_allowed`,
`needs_reauthorization`, ...), `404`, `413`, `502`, or `503`. Each brokered
request emits `[:hermitscale, :credential_broker, :request]` telemetry.

API request bodies are limited to 10 MB and Git request bodies to 100 MB. API
responses are buffered so echoed credentials can be redacted; Git responses
stream. Git LFS is not supported. Set the broker URL that Sprites can reach
with `config :hermitscale, Hermitscale.CredentialBroker, url: "https://.../broker/v1"`.
By default it is the endpoint URL plus `/broker/v1`.

To keep a Sprite from reaching anything but the broker and package registries,
set its egress policy (requires `connections:manage`):

```elixir
Workspaces.put_network_policy(scope, workspace, [
  %{include: "defaults"},
  %{domain: "hermitscale.example", action: "allow"},
  %{domain: "*", action: "deny"}
])
```
