defmodule Hermitscale.Credentials.Backends.Local.EncryptedMap do
  @moduledoc false
  use Cloak.Ecto.Map, vault: Hermitscale.Credentials.LocalVault
end
