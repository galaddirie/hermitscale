defmodule Hermitscale.Apps.Preview do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "app_previews" do
    field :org_id, :string
    field :app_id, :binary_id
    field :session_id, :binary_id
    field :workspace_id, :binary_id
    field :lease_id, :binary_id
    field :operation_key, :string
    field :source_commit, :string
    field :status, :string, default: "starting"
    field :verification, :map, default: %{}
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :lease_id,
      :operation_key,
      :source_commit,
      :status,
      :verification,
      :expires_at
    ])
    |> validate_required([
      :org_id,
      :app_id,
      :session_id,
      :workspace_id,
      :operation_key,
      :source_commit,
      :status,
      :verification,
      :expires_at
    ])
    |> unique_constraint([:app_id, :operation_key])
  end
end
