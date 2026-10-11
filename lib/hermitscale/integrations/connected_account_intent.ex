defmodule Hermitscale.Integrations.ConnectedAccountIntent do
  @moduledoc """
  Expiring local consent intent used to map a completed Pipes authorization.
  """
  # TODO: Suspect
  use Ecto.Schema
  import Ecto.Changeset

  schema "connected_account_intents" do
    field :token_hash, :binary, redact: true
    field :provider_id, :string
    field :provider_slug, :string

    field :sharing_mode, Ecto.Enum,
      values: [:private, :organization],
      default: :private

    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime

    belongs_to :owner, Hermitscale.Accounts.User, foreign_key: :owner_user_id

    belongs_to :organization, Hermitscale.Accounts.Organization,
      foreign_key: :org_id,
      type: :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(intent, attrs) do
    intent
    |> cast(attrs, [
      :token_hash,
      :owner_user_id,
      :org_id,
      :provider_id,
      :provider_slug,
      :sharing_mode,
      :expires_at,
      :consumed_at
    ])
    |> validate_required([
      :token_hash,
      :owner_user_id,
      :org_id,
      :provider_id,
      :provider_slug,
      :sharing_mode,
      :expires_at
    ])
    |> unsafe_validate_unique(:token_hash, Hermitscale.Repo)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:owner_user_id)
    |> foreign_key_constraint(:org_id)
    |> check_constraint(:sharing_mode, name: :connected_account_intents_sharing_mode_check)
  end
end
