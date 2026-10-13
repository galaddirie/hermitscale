defmodule Hermitscale.Apps.Environment do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "app_environments" do
    field :org_id, :string
    field :app_id, :binary_id
    field :workspace_id, :binary_id
    field :name, :string
    field :configuration, :map, default: %{}
    field :configuration_digest, :string
    field :active_deployment_id, :binary_id
    field :release_operation_id, :binary_id
    field :status, :string, default: "sleeping"
    field :public, :boolean, default: false
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :name,
      :configuration,
      :configuration_digest,
      :active_deployment_id,
      :release_operation_id,
      :status,
      :public
    ])
    |> validate_required([
      :org_id,
      :app_id,
      :workspace_id,
      :name,
      :configuration,
      :configuration_digest,
      :status,
      :public
    ])
    |> validate_format(:name, ~r/\A[a-z0-9-]{1,40}\z/)
    |> unique_constraint([:app_id, :name])
  end
end
