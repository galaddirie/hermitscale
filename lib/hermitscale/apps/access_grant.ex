defmodule Hermitscale.Apps.AccessGrant do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "app_access_grants" do
    field :org_id, :string
    field :app_id, :binary_id
    field :preview_id, :binary_id
    field :environment_id, :binary_id
    field :created_by_user_id, :string
    field :kind, :string
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:preview_id, :kind, :expires_at, :revoked_at])
    |> validate_required([:org_id, :app_id, :created_by_user_id, :kind, :expires_at])
  end
end
