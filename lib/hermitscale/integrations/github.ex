defmodule Hermitscale.Integrations.Github do
  @moduledoc """
  GitHub credential provider — the dual-method case: users connect via OAuth
  or paste a personal access token, and nodes accept either through the same
  credential seam.

  `refresh: :rotating` because GitHub App user access tokens invalidate the
  previous refresh token on every refresh. Classic OAuth app tokens don't
  expire and never hit the refresh path.
  """

  use Hermitscale.Integrations.Provider

  @impl true
  def provider_id, do: "github"

  @impl true
  def network_domains, do: ["api.github.com", "github.com", "uploads.github.com"]

  @impl true
  def spec do
    %{
      id: "github",
      methods: %{
        oauth: %{
          authorize_url: "https://github.com/login/oauth/authorize",
          token_url: "https://github.com/login/oauth/access_token",
          default_scopes: [],
          refresh: :rotating
        },
        api_key: %{auth: :bearer}
      }
    }
  end

  @impl true
  def fetch_token(ref, scopes) do
    Hermitscale.Credentials.fetch_token(provider_id(), ref, scopes)
  end
end
