defmodule Hermitscale.Apps.BuildSession do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "app_build_sessions" do
    field :org_id, :string
    field :app_id, :binary_id
    field :session_id, :binary_id
    field :operation_key, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:operation_key])
    |> validate_required([:org_id, :app_id, :session_id, :operation_key])
    |> unique_constraint([:app_id, :operation_key])
  end
end
