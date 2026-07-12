defmodule Hermitscale.Auth.IdentityProvider do
  @moduledoc """
  Behaviour for pluggable identity providers.

  A provider's only job is to answer "how is this person's identity
  verified": where login starts, how a hosted callback is turned into a
  normalized `Hermitscale.Auth.Identity`, and what remote cleanup logout
  needs. Everything else — session tokens, current-scope resolution,
  user/org provisioning — is provider-agnostic and lives in
  `Hermitscale.Auth` and `Hermitscale.Accounts`.

  Sessions are ALWAYS local phx.gen.auth session tokens regardless of
  provider. Hosted providers only replace the login/registration UX.

  The active provider is selected instance-wide via configuration
  (`AUTH_BACKEND` in runtime.exs), mirroring how
  `Hermitscale.Credentials.Backend` is selected. Capabilities gate both the
  optional callbacks and the UI: templates ask
  `Hermitscale.Auth.capability?/1` instead of naming providers.
  """

  alias Hermitscale.Auth.Identity

  @typedoc """
  What a provider supports:

    * `:registration` — a self-serve sign-up page exists locally
    * `:password` — password login and change-password settings
    * `:magic_link` — email magic-link login
    * `:self_service_settings` — email/password are managed in-app
    * `:hosted_login` — login starts with a redirect off-site
    * `:remote_logout` — logout must terminate an upstream session
  """
  @type capability ::
          :registration
          | :password
          | :magic_link
          | :self_service_settings
          | :hosted_login
          | :remote_logout

  @doc """
  Stable short identifier persisted on identity rows (`"local"`,
  `"workos"`), so records survive module renames.
  """
  @callback id() :: String.t()

  @callback capabilities() :: [capability()]

  @doc """
  Where an unauthenticated user is sent to log in. Local: the phx.gen.auth
  login page. Hosted: the internal redirect action (not the upstream URL
  itself — state generation needs a conn).
  """
  @callback log_in_path() :: String.t()

  # Optional — :hosted_login capability.

  @doc """
  Builds the hosted authorization URL the redirect controller sends the
  browser to. Pure URL construction, no HTTP.
  """
  @callback authorize_url(
              opts :: %{
                required(:redirect_uri) => String.t(),
                required(:state) => String.t(),
                optional(:screen_hint) => :sign_in | :sign_up
              }
            ) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Exchanges the callback authorization code for a normalized identity.
  """
  @callback exchange_code(code :: String.t(), opts :: %{required(:redirect_uri) => String.t()}) ::
              {:ok, Identity.t()} | {:error, term()}

  # Optional — :remote_logout capability.

  @doc """
  URL to send the browser to after the local session is dropped, so the
  upstream session is terminated too. `session_metadata` is whatever
  `exchange_code/2` put in `Identity.session_metadata` (carried in the Plug
  session for the lifetime of the login). Returns `:none` when there is
  nothing to terminate.
  """
  @callback logout_url(session_metadata :: map(), opts :: %{required(:return_to) => String.t()}) ::
              {:ok, String.t()} | :none

  @optional_callbacks authorize_url: 1, exchange_code: 2, logout_url: 2

  @doc "Whether a provider declares a capability."
  def capability?(provider, capability) when is_atom(provider) and is_atom(capability) do
    capability in provider.capabilities()
  end
end
