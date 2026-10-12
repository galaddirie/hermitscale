defmodule Hermitscale.Integrations.Linear do
  @moduledoc "Linear integration metadata. Personal API keys use the raw Authorization header; OAuth uses bearer authentication."
  use Hermitscale.Integrations.Provider

  @impl true
  def provider_id, do: "linear"

  @impl true
  def network_domains, do: ["api.linear.app"]

  @impl true
  def descriptor do
    %{
      slug: provider_id(),
      auth_methods: ["oauth", "api_key"],
      authentication: %{"oauth" => :bearer, "api_key" => {:header, "authorization"}},
      destinations: network_domains()
    }
  end
end
