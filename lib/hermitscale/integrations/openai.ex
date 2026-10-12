defmodule Hermitscale.Integrations.OpenAI do
  @moduledoc "OpenAI API integration using an organization-owned API key stored in Pipes."
  use Hermitscale.Integrations.Provider

  @impl true
  def provider_id, do: "openai"

  @impl true
  def network_domains, do: ["api.openai.com"]

  @impl true
  def descriptor do
    %{
      slug: provider_id(),
      auth_methods: ["api_key"],
      authentication: %{"api_key" => :bearer},
      destinations: network_domains()
    }
  end
end
