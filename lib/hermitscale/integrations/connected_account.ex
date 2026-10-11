defmodule Hermitscale.Integrations.ConnectedAccount do
  @moduledoc """
  Local authorization metadata for a WorkOS Pipes connected account.

  This schema intentionally has no provider access-token, refresh-token, or
  API-key field.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "connected_accounts" do
    field :provider_id, :string
    field :provider_slug, :string
    field :backend, Ecto.Enum, values: [:legacy_google, :workos_pipes], default: :workos_pipes
    field :workos_connected_account_id, :string
    field :workos_organization_id, :string

    field :state, Ecto.Enum,
      values: [:pending, :connected, :needs_reauthorization, :disconnecting, :disconnected],
      default: :pending

    field :sharing_mode, Ecto.Enum,
      values: [:private, :organization],
      default: :private

    field :granted_scopes, {:array, :string}, default: []
    field :workos_updated_at, :utc_datetime_usec
    field :disconnected_at, :utc_datetime
    field :deleted_at, :utc_datetime

    belongs_to :owner, Hermitscale.Accounts.User, foreign_key: :owner_user_id

    belongs_to :organization, Hermitscale.Accounts.Organization,
      foreign_key: :org_id,
      type: :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def create_changeset(account, attrs) do
    account
    |> cast(attrs, [
      :owner_user_id,
      :org_id,
      :provider_id,
      :provider_slug,
      :backend,
      :workos_connected_account_id,
      :workos_organization_id,
      :state,
      :sharing_mode,
      :granted_scopes,
      :workos_updated_at,
      :disconnected_at,
      :deleted_at
    ])
    |> validate_required([
      :owner_user_id,
      :org_id,
      :provider_id,
      :provider_slug,
      :backend,
      :state,
      :sharing_mode
    ])
    |> validate_length(:provider_id, max: 255)
    |> validate_length(:provider_slug, max: 255)
    |> validate_scopes()
    |> apply_constraints()
  end

  @doc false
  def sync_changeset(account, attrs) do
    account
    |> cast(attrs, [
      :workos_connected_account_id,
      :state,
      :granted_scopes,
      :workos_updated_at,
      :disconnected_at,
      :deleted_at,
      :sharing_mode
    ])
    |> validate_scopes()
    |> apply_constraints()
  end

  @doc false
  def state_changeset(account, attrs) do
    account
    |> cast(attrs, [:state, :disconnected_at, :deleted_at])
    |> validate_required([:state])
    |> apply_constraints()
  end

  @doc false
  def sharing_changeset(account, attrs) do
    account
    |> cast(attrs, [:sharing_mode])
    |> validate_required([:sharing_mode])
    |> apply_constraints()
  end

  defp validate_scopes(changeset) do
    validate_change(changeset, :granted_scopes, fn :granted_scopes, scopes ->
      case Enum.all?(scopes, &(is_binary(&1) and byte_size(&1) <= 255)) do
        true -> []
        false -> [granted_scopes: "must contain valid scope strings"]
      end
    end)
  end

  defp apply_constraints(changeset) do
    changeset
    |> unsafe_validate_unique(:workos_connected_account_id, Hermitscale.Repo)
    |> unique_constraint(:workos_connected_account_id)
    |> unique_constraint(
      [:owner_user_id, :provider_slug, :workos_organization_id],
      name: :connected_accounts_workos_tuple_with_org_index
    )
    |> unique_constraint([:owner_user_id, :provider_slug],
      name: :connected_accounts_workos_tuple_without_org_index
    )
    |> foreign_key_constraint(:owner_user_id)
    |> foreign_key_constraint(:org_id)
    |> check_constraint(:backend, name: :connected_accounts_backend_check)
    |> check_constraint(:state, name: :connected_accounts_state_check)
    |> check_constraint(:sharing_mode, name: :connected_accounts_sharing_mode_check)
  end
end
