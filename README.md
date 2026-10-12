# Hermitscale

Requires Elixir 1.18 or later. Runic is fetched from GitHub's `main` branch;
`mix.lock` pins the validated revision. `mix deps.update runic` advances that
revision and should be followed by `mix precommit` and collection/replay checks.

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

Workflow collections use native Runic Map/Reduce components and named Reduce
output connections. Full Facts and incremental events retain per-item ancestry
and zero-based indexes for iteration inspection; terminal `Run.output` contains
only final outputs.

Recovery records a compiled-definition fingerprint before execution and replays
incremental events against a matching compiled graph. Changed connections,
component identities, policies or authored expression context are rejected with
`{:error, :incompatible_workflow_events}`. Histories from the removed vendor fork
or without a definition record are not migrated automatically. Keep callback code
and the compiled-expression representation compatible when resuming runs.

## Authentication and scopes

WorkOS owns users, organizations, memberships, authentication, and provider OAuth
credentials. Hermitscale has no local identity, session, connected-account, or
WorkOS synchronization tables. `Hermitscale.Accounts.Scope` carries verified
WorkOS user and organization IDs in memory; workflow queries still require the
scope as their first argument.

The web layer starts with a public welcome page. `/auth/sign-in` redirects to
Hosted AuthKit, `/auth/workos/callback` exchanges the code and verifies the access
JWT, and `DELETE /users/log-out` revokes the WorkOS session. Browser credentials
are held in an encrypted, HttpOnly cookie. JWT signature, issuer, client, subject,
session, expiration, and organization continuity are checked before granting a
scope. Expiring tokens refresh through WorkOS. An identity without an organization
can sign in but cannot access organization-owned workflows.

Set `WORKOS_API_KEY`, `WORKOS_CLIENT_ID`, and `WORKOS_REDIRECT_URI` for AuthKit;
the redirect URI must match the callback registered in WorkOS. Production also
requires the usual `DATABASE_URL`, `SECRET_KEY_BASE`, and `PHX_HOST` settings.
WorkOS webhook and token-encryption-key settings are no longer needed: browser
session encryption derives from Phoenix's `SECRET_KEY_BASE`.

Without an event mirror, remote revocation and permission changes take effect at
WorkOS token refresh, bounded by the access JWT lifetime. Concurrent requests near
expiry may race refresh-token rotation and require signing in again; there is no
local session lock or synchronization worker.

Workflow credentials store a provider reference. Token vending uses the graph's
WorkOS creator and organization IDs through Pipes immediately before the provider
request. Only the creator may edit, run, or resume workflows bound to their credentials;
other members can use workflows without credential bindings within the organization. Legacy local
connected-account references require rebinding.

The removal migration preserves workflow records, replaces known local identity
IDs with their WorkOS mappings, cancels pending identity-sync jobs, and drops the
old projection tables. Unmapped legacy records remain orphaned rather than being
deleted. The migration cannot reconstruct removed identity data on rollback; use a
database backup if rollback is needed. Development data is only changed when you
apply the migration with `mix ecto.migrate`.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
