defmodule Hermitscale.Credentials.Credential do
  @moduledoc """
  Queryable metadata record for one stored credential.

  Holds no secret material by construction — the payload lives with the
  backend named in `backend`, addressed by the opaque `external_ref`. The row
  survives revocation (with `status: :revoked` and material deleted) so the
  audit trail in `credential_events` keeps its subject.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @statuses [:pending_connect, :active, :expired, :reauth_required, :revoked]

  schema "credentials" do
    field :org_id, :string
    field :user_id, :string
    field :provider, :string
    field :kind, Ecto.Enum, values: [:oauth, :api_key, :custom]
    field :method, :string
    field :name, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending_connect
    field :backend, :string
    field :external_ref, :string
    field :provider_metadata, :map, default: %{}
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime
    field :last_used_at, :utc_datetime
    field :rotated_at, :utc_datetime

    has_many :events, Hermitscale.Credentials.CredentialEvent

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :id,
      :org_id,
      :user_id,
      :provider,
      :kind,
      :method,
      :name,
      :status,
      :backend,
      :external_ref,
      :provider_metadata,
      :scopes,
      :expires_at,
      :last_used_at,
      :rotated_at
    ])
    |> validate_required([:id, :org_id, :provider, :kind, :method, :name, :status, :backend])
  end
end
