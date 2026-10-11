defmodule Hermitscale.WorkOS.AuthSession do
  @moduledoc """
  Server-side holder for one WorkOS-authoritative browser session.

  The browser receives only the random handle whose SHA-256 hash is stored in
  `token_hash`. WorkOS access and refresh tokens are authenticated ciphertext.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type :id

  schema "auth_sessions" do
    field :token_hash, :binary, redact: true
    field :workos_session_id, :string
    field :encryption_key_id, :string
    field :access_token_ciphertext, :binary, redact: true
    field :refresh_token_ciphertext, :binary, redact: true
    field :access_expires_at, :utc_datetime
    field :authenticated_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, Hermitscale.Accounts.User

    belongs_to :organization, Hermitscale.Accounts.Organization,
      foreign_key: :org_id,
      type: :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :token_hash,
      :user_id,
      :org_id,
      :workos_session_id,
      :encryption_key_id,
      :access_token_ciphertext,
      :refresh_token_ciphertext,
      :access_expires_at,
      :authenticated_at
    ])
    |> validate_required([
      :token_hash,
      :user_id,
      :workos_session_id,
      :encryption_key_id,
      :access_token_ciphertext,
      :refresh_token_ciphertext,
      :access_expires_at,
      :authenticated_at
    ])
    |> unsafe_validate_unique(:token_hash, Hermitscale.Repo)
    |> unique_constraint(:token_hash)
    |> unsafe_validate_unique(:workos_session_id, Hermitscale.Repo)
    |> unique_constraint(:workos_session_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:org_id)
  end

  @doc false
  def rotate_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :org_id,
      :encryption_key_id,
      :access_token_ciphertext,
      :refresh_token_ciphertext,
      :access_expires_at
    ])
    |> validate_required([
      :encryption_key_id,
      :access_token_ciphertext,
      :refresh_token_ciphertext,
      :access_expires_at
    ])
    |> foreign_key_constraint(:org_id)
  end

  @doc false
  def revoke_changeset(session, revoked_at) do
    change(session, revoked_at: revoked_at)
  end
end
