defmodule Hermitscale.WorkspaceWorker.MixProject do
  use Mix.Project

  def project do
    [
      app: :workspace_worker,
      version: "0.1.0",
      elixir: if(Mix.env() == :core, do: "~> 1.18", else: "~> 1.19"),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [precommit: ["compile --warnings-as-errors", "format --check-formatted", "test"]]
    ]
  end

  def application do
    [mod: {Hermitscale.WorkspaceWorker.Application, []}, extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:workspace_protocol, path: "../priv/workspace_protocol/v1"},
      {:req, "~> 0.5"},
      {:jido_harness,
       git: "https://github.com/agentjido/jido_harness.git",
       ref: "2cea7100174de3aae3ece358612f2405a175217f",
       only: [:dev, :test, :prod]}
    ]
  end
end
