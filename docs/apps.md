# Apps

An app publishes a workspace's HTTP service at `https://<slug>.<APPS_DOMAIN>`. See the
[design](agent-apps-design.md#apps) for the reasoning.

## Configuration

- `APPS_DOMAIN`: a domain separate from the main app, such as `hermitscale.app`, with
  wildcard DNS and TLS for `*.APPS_DOMAIN` pointing at Hermitscale. Dev uses
  `apps.localhost`; without it, apps are disabled. Consider adding the domain to the
  [Public Suffix List](https://publicsuffix.org) so apps can't share cookies.
- Register `<main host>/apps/auth/callback` as a redirect URI with the identity provider.

## API

Every function takes a verified scope and requires `workflows:run`.

```elixir
{:ok, _} =
  Workspaces.put_service(scope, workspace.id, "web", %{
    cmd: "python3",
    args: ["-m", "http.server", "8080"],
    http_port: 8080
  })

{:ok, app} = Apps.create_app(scope, workspace.id, %{slug: "reports", access: :org})
Apps.app_url(app)
#=> "https://reports.hermitscale.app"

{:ok, app} = Apps.update_app(scope, app, %{access: :public})
{:ok, _} = Apps.delete_app(scope, app)
{:ok, apps} = Apps.list_apps(scope)
```

Each workspace has at most one app. Slugs are lowercase DNS labels and globally unique.
Deleting the workspace deletes its app. Changes to the workspace are live; checkpoint
before risky edits.

## Access

- `public`: anyone with the URL.
- `org`: active members of the app's organization. Visitors sign in through the identity
  provider and get a 12-hour cookie for that app host. Membership is checked at sign-in.

The app receives `x-hermitscale-user-id` and `x-hermitscale-user-email` for signed-in
visitors. These headers are always stripped from incoming requests, along with
`Authorization` and Hermitscale cookies, so apps can trust them.

## Limits

- No WebSocket forwarding yet.
- Request bodies are capped at 25 MB.
- `/_hermitscale/*` and `/live/*` are reserved on app hosts.
- The Sprite URL stays private; the proxy authenticates to it with the Sprites token.
  Setting a workspace's URL auth to `public` would expose it outside the proxy.
