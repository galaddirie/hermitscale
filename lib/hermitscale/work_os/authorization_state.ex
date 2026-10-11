defmodule Hermitscale.WorkOS.AuthorizationState do
  @moduledoc """
  Single-use, expiring state for the Hosted AuthKit authorization callback.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "workos_authorization_states" do
    field :token_hash, :binary, redact: true
    field :return_to, :string
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def create_changeset(state, attrs) do
    state
    |> cast(attrs, [:token_hash, :return_to, :expires_at])
    |> validate_required([:token_hash, :return_to, :expires_at])
    |> validate_length(:return_to, max: 2_048)
    |> unsafe_validate_unique(:token_hash, Hermitscale.Repo)
    |> unique_constraint(:token_hash)
  end

  @doc false
  def consume_changeset(state, consumed_at) do
    change(state, consumed_at: consumed_at)
  end
end
