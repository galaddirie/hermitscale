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
