defmodule Hermitscale.Credentials.AccessToken do
  @moduledoc """
  A short-lived OAuth access token returned by managed-OAuth backends and by
  the shared refresh path. Redacts the token from `inspect/1`.
  """

  @enforce_keys [:access_token]
  defstruct [:access_token, :expires_at, scopes: []]

  @type t :: %__MODULE__{
          access_token: String.t(),
          expires_at: DateTime.t() | nil,
          scopes: [String.t()]
        }

  defimpl Inspect do
    def inspect(token, _opts) do
      "#Credentials.AccessToken<expires_at: #{inspect(token.expires_at)}, redacted>"
    end
  end
end
