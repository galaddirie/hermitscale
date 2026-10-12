defmodule Hermitscale.Integrations.Google do
  @moduledoc """
  Shared defaults for Google catalog nodes.
  """

  use Hermitscale.Integrations.Provider

  @provider "google"
  @default_policy %{backoff: "exponential", max_retries: 3, timeout_ms: 30_000}

  defmacro __using__(opts) do
    {opts, _binding} = Code.eval_quoted(opts, [], __CALLER__)
    {scopes, opts} = Keyword.pop(opts, :scopes, [])

    opts =
      opts
      |> Keyword.put(:requires, credentials: [provider: @provider, scopes: scopes])
      |> Keyword.put_new(:default_policy, @default_policy)

    quote do
      use Hermitscale.Workflows.Nodes.Behaviour, unquote(Macro.escape(opts))
    end
  end

  @impl true
  def descriptor,
    do: %{
      slug: "google",
      auth_methods: ["oauth"],
      authentication: %{"oauth" => :bearer},
      destinations: network_domains()
    }

  @impl true
  def network_domains, do: ["sheets.googleapis.com", "www.googleapis.com"]
  @impl true
  def provider_id, do: @provider
end
