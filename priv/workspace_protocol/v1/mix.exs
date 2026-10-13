defmodule Hermitscale.WorkspaceProtocol.MixProject do
  use Mix.Project

  def project do
    [app: :workspace_protocol, version: "1.0.0", elixir: "~> 1.18", deps: []]
  end

  def application, do: [extra_applications: [:crypto]]
end
