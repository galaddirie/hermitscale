defmodule Hermitscale.Credentials.Resolved do
  @moduledoc """
  The runtime shape a credential resolves to.

  `auth` maps directly onto what `Hermitscale.HTTP.request/3` accepts, so API
  keys, OAuth tokens, and custom secrets are uniform at the call site.
  """

  @enforce_keys [:credential_id, :provider, :method, :auth]
  defstruct [:credential_id, :provider, :method, :auth, :expires_at, scopes: []]

  @type auth ::
          {:bearer, String.t()}
          | {:header, name :: String.t(), value :: String.t()}
          | {:basic, userinfo :: String.t()}
          | {:fields, %{String.t() => String.t()}}

  @type t :: %__MODULE__{
          credential_id: String.t(),
          provider: String.t(),
          method: atom(),
          auth: auth(),
          expires_at: DateTime.t() | nil,
          scopes: [String.t()]
        }

  defimpl Inspect do
    def inspect(resolved, _opts) do
      "#Credentials.Resolved<credential_id: #{inspect(resolved.credential_id)}, " <>
        "provider: #{inspect(resolved.provider)}, method: #{inspect(resolved.method)}, redacted>"
    end
  end
end
