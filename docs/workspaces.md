# Workspaces

`Hermitscale.Workspaces` stores organization-owned workspaces backed by
[Fly Sprites](https://docs.fly.io/sprites). It is a backend context; it does not
add browser routes or change the current authentication flow.

Every public operation takes a verified `Hermitscale.Accounts.Scope` first and
checks current active membership through the configured auth provider. Every
member can use every workspace in the selected organization. Creator IDs record
provenance and do not control access. Organization and user IDs are opaque strings
owned by the auth provider, without local identity foreign keys.

There are no application workspace-count, command-runtime, output-size, file-size,
or role-based usage quotas. Provider resource, concurrency, billing, and rate limits
still apply. Synchronous execution buffers its result in the caller; use `spawn`
and consume output as it arrives for long-lived or high-output commands.

## Configuration

Set `SPRITES_API_KEY` to a server-side Sprites token. `SPRITE_TOKEN`, used in Fly's
examples, is also accepted when `SPRITES_API_KEY` is unset or empty. Optional
`SPRITES_API_BASE_URL` defaults to `https://api.sprites.dev`. Keep these values in
the server environment; never send the token to clients or store it in a workspace.
Without a token, remote operations return `{:error, :not_configured}`.

Run `mix ecto.migrate` to create the `sprite_workspaces` table. This table avoids
colliding with legacy workspace storage from earlier application versions. The
migration does not create sprites or modify existing workflow records.

The integration uses Req for REST and the
[official Elixir SDK](https://github.com/superfly/sprites-ex) for WebSocket command
execution. The SDK's checkpoint HTTP transport is bypassed in favor of Req.
Tests replace the context client with a fake and exercise the REST protocol with
`Req.Test`. A local WebSocket server also exercises the actual SDK's command
protocol and transport cleanup, without consuming live provider resources.

## Creation and recovery

```elixir
alias Hermitscale.Workspaces

# scope comes from the verified provider session, not from request parameters.
{:ok, workspace} =
  Workspaces.create_workspace(scope, %{
    name: "Development",
    description: "Shared development environment"
  })

{:ok, workspaces} = Workspaces.list_workspaces(scope)
{:ok, workspace} = Workspaces.fetch_workspace(scope, workspace.id)
```

Only the name and description come from the caller. Workspace IDs, organization,
creator, remote name, and lifecycle state are set by the server. Display names can
repeat; each sprite has a unique generated provider name. Supplying a workspace
struct refetches its stored identity before use, so changing its tenant or sprite
name cannot redirect an operation to another resource.

Creation saves a `:provisioning` record before the remote request. A provider
failure retains that record with a sanitized error code, rather than losing the
identity of a sprite that may have been created. Uncertain failures remain
`:provisioning`; definitive rejections become `:failed`. After an error, list workspaces
and call `refresh_workspace(scope, id)` to reconcile provider state. If provisioning
has not succeeded and Fly confirms absence, refresh can retry the same remote name.
Refresh never silently replaces a previously provisioned sprite whose files have
gone missing. Creation, refresh, and deletion serialize on each workspace's
database row. Retry intent commits before another remote creation request, so a
caller crash leaves enough local state to reconcile its outcome.

`:ready` means provisioning succeeded; the provider's `cold`, `warm`, or `running`
status lives in `workspace.sprite_data`. These states do not restrict command use.

```elixir
{:ok, workspace} = Workspaces.refresh_workspace(scope, workspace.id)
{:ok, deleted_workspace} = Workspaces.delete_workspace(scope, workspace.id)
```

Deletion returns `{:error, :provisioning}` while creation is in flight or its outcome
is uncertain; reconcile it with refresh first. Otherwise it records `:deleting`,
then deletes remotely, then removes the local
record. A remote failure retains deletion intent for retry. A missing remote
sprite is already deleted. Membership or creator removal does not delete shared
sprites. Automatic cleanup on organization deletion is not wired to a provider
event consumer; delete its workspaces while the organization is still accessible.

## Commands

Commands execute inside the sprite. Arguments, environment, working directory,
root access, and installed tools are not filtered by application policy.

```elixir
{:ok, %{stdout: stdout, stderr: stderr, exit_code: exit_code}} =
  Workspaces.execute(scope, workspace.id, "bash", ["-lc", "pwd; echo hello"],
    dir: "/home/sprite",
    env: [{"COLOR", "blue"}]
  )
```

A nonzero exit code is a completed command result, not a transport error. Runtime
is unlimited by default. Use a caller-supplied timeout when your own operation
needs a deadline.

```elixir
{:ok, command} =
  Workspaces.spawn(scope, workspace.id, "bash", [],
    stdin: true,
    tty: true,
    session_info: true
  )

Sprites.write(command, "pwd\n")
Sprites.resize(command, 40, 120)

ref = command.ref

receive do
  {:stdout, %{ref: ^ref}, bytes} -> IO.binwrite(bytes)
  {:stderr, %{ref: ^ref}, bytes} -> IO.binwrite(:stderr, bytes)
  {:exit, %{ref: ^ref}, code} -> IO.inspect(code)
  {:error, %{ref: ^ref}, reason} -> IO.inspect(reason)
  {:session_info, %{ref: ^ref}, session_id} -> IO.inspect(session_id)
end
```

The receive example handles one event; a consumer should loop until exit or error
and consume stdout and stderr throughout. Match the reference in the event's map,
not the full command struct. Handles are for backend process use and omit the
SDK's token-bearing sprite. A supervised guardian closes the local command
transport when its owner exits. Opening a command checks membership; already
running work follows the provider's session lifecycle.

For piped input, pass `stdin: true`, write input, and call
`Sprites.close_stdin(command)` to send EOF. TTY commands need terminal EOF or an
explicit shell exit. Detached commands may keep running after the transport
closes; closing a WebSocket is not confirmation that a remote process stopped.

```elixir
{:ok, sessions} = Workspaces.list_sessions(scope, workspace.id)
{:ok, command} = Workspaces.attach_session(scope, workspace.id, session_id, stdin: true)
{:ok, progress} = Workspaces.kill_session(scope, workspace.id, session_id)
```

Session operations refetch the workspace and check membership like other
capabilities. Session IDs come from provider listings or the `:session_info` event.
Kill reports success only after the provider's completion event.

## Files, checkpoints, and services

```elixir
{:ok, file} = Workspaces.write_file(scope, workspace.id, "/tmp/example.txt", "hello\n")
{:ok, bytes} = Workspaces.read_file(scope, workspace.id, "/tmp/example.txt")
{:ok, listing} = Workspaces.list_files(scope, workspace.id, "/tmp")
:ok = Workspaces.delete_file(scope, workspace.id, "/tmp/example.txt")

{:ok, checkpoints} = Workspaces.list_checkpoints(scope, workspace.id)
{:ok, progress} = Workspaces.create_checkpoint(scope, workspace.id, comment: "Before changes")
{:ok, progress} = Workspaces.restore_checkpoint(scope, workspace.id, checkpoint_id)

{:ok, service} =
  Workspaces.put_service(scope, workspace.id, "web", %{
    "cmd" => "python3",
    "args" => ["-m", "http.server", "8080"],
    "needs" => [],
    "http_port" => 8080
  })

{:ok, services} = Workspaces.list_services(scope, workspace.id)
{:ok, service} = Workspaces.get_service(scope, workspace.id, "web")
:ok = Workspaces.delete_service(scope, workspace.id, "web")

{:ok, settings} = Workspaces.update_url_settings(scope, workspace.id, %{"auth" => "public"})
```

Sprite URLs begin private (`auth: "sprite"`). Making one public is an explicit
organization member action. File and service options follow the
[Sprites documentation](https://docs.fly.io/sprites). File paths
refer to the sprite's filesystem, never the application host. Binary files are
supported without conversion to UTF-8. Checkpoint operations inspect the complete
progress response and report terminal provider failures.

Cross-organization or missing workspace IDs return `{:error, :not_found}`.
Ineligible membership returns `{:error, :forbidden}`. Auth/provider outages remain
errors such as `:unavailable` and `:rate_limited`; failed remote work is never
reported as successful local work.
