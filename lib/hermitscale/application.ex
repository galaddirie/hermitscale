defmodule Hermitscale.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = Hermitscale.Auth.validate_provider!()

    children = [
      HermitscaleWeb.Telemetry,
      Hermitscale.Repo,
      {Oban, Application.fetch_env!(:hermitscale, Oban)},
      {DNSCluster, query: Application.get_env(:hermitscale, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Hermitscale.PubSub},
      {Task.Supervisor, name: Hermitscale.Workspaces.CommandSupervisor},
      {Runic.Runner,
       name: Hermitscale.WorkflowRunner,
       store: Hermitscale.Workflows.PostgresStore,
       store_opts: [repo: Hermitscale.Repo]},
      {Hermitscale.Triggers.Supervisor, []},
      # Start to serve requests, typically the last entry
      HermitscaleWeb.Endpoint,
      HermitscaleWeb.AppsEndpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Hermitscale.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HermitscaleWeb.Endpoint.config_change(changed, removed)
    HermitscaleWeb.AppsEndpoint.config_change(changed, removed)
    :ok
  end
end
