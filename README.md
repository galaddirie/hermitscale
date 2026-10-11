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
only final outputs. See the [Runic validation](docs/research/runic-main-application-validation.md)
for executable examples.

Recovery records a compiled-definition fingerprint before execution and replays
incremental events against a matching compiled graph. Changed connections,
component identities, policies or authored expression context are rejected with
`{:error, :incompatible_workflow_events}`. Histories from the removed vendor fork
or without a definition record are not migrated automatically. Keep callback code
and the compiled-expression representation compatible when resuming runs.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
