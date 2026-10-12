defmodule Hermitscale.Integrations.Google.OAuth do
  @moduledoc """
  Google credential adapter backed by WorkOS Pipes.

  Tokens are vended for each immediate provider request, checking both the
  credential reference's requirements and any additional caller scopes.
  """

  use Hermitscale.Integrations.Provider

  alias Hermitscale.Integrations.{ConnectedAccounts, CredentialRef}

  @impl true
  def provider_id, do: "google.oauth"

  @impl true
  def network_domains, do: ["sheets.googleapis.com", "www.googleapis.com"]

  @impl true
  def fetch_token(ref, scopes \\ [])

  def fetch_token(%CredentialRef{provider_id: "google.oauth"} = ref, scopes)
      when is_list(scopes) do
    %{ref | required_scopes: Enum.uniq(ref.required_scopes ++ scopes)}
    |> ConnectedAccounts.fetch_oauth_token()
  end

  def fetch_token(_ref, _scopes), do: {:error, :missing_credential_identity}
end
