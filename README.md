# Hermitscale

Requires Elixir 1.18 or later. Runic is fetched from GitHub's `main` branch;
`mix.lock` pins the validated revision. `mix deps.update runic` advances that
revision and should be followed by `mix precommit` and collection/replay checks.

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

Workflow execution uses Runic's native single-output lifecycle and focused
collection coordinators. Maps support branching, correlated joins, and nested
scopes. Reduce folds in source order; aggregate collects ordered values. Empty
collections return the reduce seed or `[]`. Facts and accepted events preserve
occurrence identity, lineage, and local upstream history; runtime credentials
remain separate. See the [node authoring guide](docs/node-authoring-kit.md).
Terminal `Run.output` contains successful final payloads and excludes internal
empty and skipped outcomes.

Recovery records a compiled-definition fingerprint before execution and replays
incremental events against a matching compiled graph. Changed connections,
component identities, policies or authored expression context are rejected with
`{:error, :incompatible_workflow_events}`. Histories from the removed vendor fork
or without a definition record are not migrated automatically. Keep callback code
and the compiled-expression representation compatible when resuming runs.

## Authentication and scopes

The configured auth provider owns users, organizations, memberships, and
authentication. WorkOS is the default; its adapter handles AuthKit calls, JWT
verification, encrypted sessions, and native data mapping. Hermitscale has no
local identity or session tables. `Hermitscale.Accounts.Scope` carries verified,
opaque user and organization IDs in memory; workflow queries require the scope
as their first argument.

The web layer is the stock Phoenix 1.8.8 scaffold, with its generated starter
page, layouts, components, browser/API pipelines, and development tools. Browser
authentication, workspace switching, and workflow screens are deferred until the
backend is ready. There are no application sign-in, callback, or logout routes.

Backend authentication and organization APIs remain available through
`Hermitscale.Auth` and `Hermitscale.Accounts`. `Auth.sign_in/2` exchanges a code,
provisions a personal organization, and selects it when no tenant was supplied.
Session verification,
refresh, tenant switching, and personal-organization provisioning are tested
independently of the web layer. Select any implementation of
`Hermitscale.Auth.Provider` in environment configuration:

```elixir
config :hermitscale, Hermitscale.Auth, provider: MyApp.AuthProvider
```

The provider behaviour documents normalized identity and session results. The
application validates its callbacks at startup and reads the selection at
runtime. A release can override it with `AUTH_PROVIDER=MyApp.AuthProvider`; the
module must be compiled into the release. Alternate auth providers do not require
WorkOS auth credentials at startup. Existing IDs are retained when changing
providers; migrating identity ownership requires preserving or mapping those IDs.

WorkOS Pipes remains the separate credential service and still needs
`WORKOS_API_KEY` when used. Configure application roles and Pipes providers
manually; the credential contract and permission matrix are documented in
[the node authoring guide](docs/node-authoring-kit.md#8-credentials).

Each credentialed workflow node selects an organization-owned account through a
canonical `connection` object. Permitted members use the same saved account;
execution uses the verified caller or the actor recorded on an automation.
Provider requests validate current membership, permissions, scopes, and allowed
destinations before vending credential material. Runs preserve actor provenance
and account selections for resume. Legacy credential binding formats are rejected.

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
