defmodule Hermitscale.Credentials.LocalVault do
  @moduledoc """
  Cloak vault encrypting credential secrets stored by the local backend.

  Ciphers come from `config :hermitscale, Hermitscale.Credentials.LocalVault`
  — static keys in dev/test, `CLOAK_KEY` via `config/runtime.exs` in
  production. Master-key rotation follows Cloak's multi-key flow: add the new
  key as `:default`, keep the old as a retired cipher, re-encrypt, remove.
  """

  use Cloak.Vault, otp_app: :hermitscale
end
