defmodule Hermitscale.Apps.Backup do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "app_backups" do
    field :org_id, :string
    field :environment_id, :binary_id
    field :artifact_id, :binary_id
    field :digest, :string
    field :source_deployment_id, :binary_id
    field :verification, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:artifact_id, :digest, :source_deployment_id, :verification])
    |> validate_required([:org_id, :environment_id, :artifact_id, :digest, :verification])
  end
end
