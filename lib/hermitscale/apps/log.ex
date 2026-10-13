defmodule Hermitscale.Apps.Log do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "app_logs" do
    field :org_id, :string
    field :app_id, :binary_id
    field :environment_id, :binary_id
    field :deployment_id, :binary_id
    field :kind, :string
    field :content, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:deployment_id, :kind, :content])
    |> validate_required([:org_id, :app_id, :kind, :content])
  end
end
