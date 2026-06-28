defmodule Hermitscale.Integrations.TestProvider do
  @moduledoc false

  use Hermitscale.Integrations.Provider

  @impl true
  def provider_id, do: "test.credentials"

  @impl true
  def fetch_token(%{"fail" => true}, _scopes), do: {:error, :test_provider_failed}

  def fetch_token(ref, scopes) do
    credential_id = Map.fetch!(ref, "credential_id")

    {:ok,
     %{
       access_token: "token:#{credential_id}",
       expires_at: nil,
       scopes: scopes
     }}
  end

  @impl true
  def network_domains, do: ["test.local"]
end
