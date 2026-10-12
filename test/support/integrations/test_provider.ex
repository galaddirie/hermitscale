defmodule Hermitscale.Integrations.TestProvider do
  @moduledoc false
  use Hermitscale.Integrations.Provider
  @impl true
  def provider_id, do: "test.credentials"
  @impl true
  def network_domains, do: ["test.local"]
  @impl true
  def descriptor,
    do: %{
      slug: "test.credentials",
      auth_methods: ["oauth", "api_key"],
      authentication: %{"oauth" => :bearer, "api_key" => {:header, "x-api-key"}},
      destinations: network_domains()
    }
end
