defmodule Hermitscale.Integrations.Google.OAuth do
  @moduledoc """
  Google OAuth credentials are managed by WorkOS Pipes.
  """

  use Hermitscale.Integrations.Provider

  alias Hermitscale.Integrations.{ConnectedAccounts, CredentialRef}

  @impl true
  def provider_id, do: "google.oauth"

  @impl true
  def network_domains, do: ["sheets.googleapis.com", "www.googleapis.com"]

  @impl true
  def fetch_token(%CredentialRef{provider_id: "google.oauth"} = ref, _scopes),
    do: ConnectedAccounts.fetch_oauth_token(ref)

  def fetch_token(_ref, _scopes), do: {:error, :missing_credential_identity}
end
