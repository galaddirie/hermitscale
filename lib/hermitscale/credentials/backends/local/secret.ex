defmodule Hermitscale.Credentials.Backends.Local.Secret do
  @moduledoc """
  Encrypted secret material for one credential version (local backend only).

  `payload` is AES-256-GCM ciphertext at rest via `cloak_ecto`; it decrypts to
  the `Hermitscale.Credentials.SecretPayload` map shape.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :string

  schema "credential_secrets" do
    field :payload, Hermitscale.Credentials.Backends.Local.EncryptedMap
    field :version, :integer

    belongs_to :credential, Hermitscale.Credentials.Credential

    timestamps(type: :utc_datetime)
  end

  def changeset(secret, attrs) do
    secret
    |> cast(attrs, [:credential_id, :payload, :version])
    |> validate_required([:credential_id, :payload, :version])
    |> foreign_key_constraint(:credential_id)
    |> unique_constraint([:credential_id, :version])
  end
end
