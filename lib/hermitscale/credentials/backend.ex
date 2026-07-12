defmodule Hermitscale.Credentials.Backend do
  @moduledoc """
  Behaviour for pluggable credential storage backends.

  A backend's only required job is to hold secret material encrypted at rest:
  `put_secret/2`, `get_secret/2`, `delete_secret/2`. Everything else —
  metadata, scoping, status lifecycle, refresh orchestration, audit — lives in
  the `Hermitscale.Credentials` context and behaves identically across
  backends.

  Backends that natively manage the OAuth lifecycle (WorkOS Pipes runs the
  authorization flow, stores refresh tokens, and returns always-fresh access
  tokens) declare the `:managed_oauth` capability and implement the optional
  callbacks. For backends without it, the shared layer runs the OAuth flow and
  refresh itself on top of the three storage primitives.

  Every callback receives a `ctx` carrying the tenancy scope and credential
  identity so backends can bind material to the tenant (e.g. WorkOS Vault key
  contexts).
  """

  alias Hermitscale.Credentials.{AccessToken, SecretPayload}

  @typedoc "Backend-specific pointer to stored material (row id, Vault object id, Pipes connection id)."
  @type external_ref :: String.t()

  @typedoc """
  Tenancy and identity context for every backend call.

  `external_ref` is present when material already exists for the credential
  (rotation, refresh persistence) so remote backends can update the existing
  object in place instead of orphaning it.
  """
  @type ctx :: %{
          required(:credential_id) => String.t(),
          required(:provider) => String.t(),
          required(:org_id) => String.t(),
          optional(:user_id) => String.t() | nil,
          optional(:external_ref) => external_ref() | nil
        }

  @type capability :: :managed_oauth | :secret_versions | :native_audit

  @doc """
  Stable short identifier stored on each credential row (e.g. `"local"`,
  `"workos"`), so records survive module renames and deployments can mix
  backends per credential.
  """
  @callback id() :: String.t()

  @callback capabilities() :: [capability()]

  @callback put_secret(SecretPayload.t(), ctx()) :: {:ok, external_ref()} | {:error, term()}
  @callback get_secret(external_ref(), ctx()) ::
              {:ok, SecretPayload.t()} | {:error, :not_found | term()}
  @callback delete_secret(external_ref(), ctx()) :: :ok | {:error, term()}

  # Optional — :managed_oauth capability.

  @doc """
  Returns what the frontend needs to start a connect flow (an authorization
  URL, or widget configuration for backends with an embedded connect UI).
  """
  @callback connect_config(provider :: String.t(), ctx()) :: {:ok, map()} | {:error, term()}

  @callback get_oauth_token(external_ref(), ctx()) ::
              {:ok, AccessToken.t()} | {:error, :reauth_required} | {:error, term()}

  @callback disconnect(external_ref(), ctx()) :: :ok | {:error, term()}

  @optional_callbacks connect_config: 2, get_oauth_token: 2, disconnect: 2

  @doc "Whether a backend declares a capability."
  def capability?(backend, capability) when is_atom(backend) and is_atom(capability) do
    capability in backend.capabilities()
  end
end
