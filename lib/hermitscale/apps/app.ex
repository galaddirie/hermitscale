defmodule Hermitscale.Apps.App do
  @moduledoc "An organization-owned app using one retained coding workspace and native Sprite service."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "apps" do
    field :org_id, :string
    field :created_by_user_id, :string
    field :name, :string
    field :slug, :string
    field :repository, :string
    field :session_id, :binary_id
    field :start_command, :string
    field :port, :integer, default: 8080
    field :native_url, :string
    field :source_commit, :string
    field :service_status, :string, default: "stopped"
    field :public, :boolean, default: false
    field :operation_key, :string, virtual: true
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(app, attrs) do
    app
    |> cast(attrs, [:name, :slug, :repository, :operation_key])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:org_id, :created_by_user_id, :name, :slug])
    |> validate_length(:name, min: 1, max: 160)
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
    |> validate_length(:slug, max: 80)
    |> validate_format(:repository, ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)
    |> unique_constraint([:org_id, :slug])
  end

  def service_changeset(app, attrs) do
    app
    |> cast(attrs, [:start_command, :port])
    |> update_change(:start_command, &String.trim/1)
    |> validate_required([:start_command, :port])
    |> validate_length(:start_command, min: 1, max: 4096)
    |> validate_format(:start_command, ~r/\A[^\x00]+\z/)
    |> validate_number(:port, greater_than: 0, less_than: 65_536)
  end
end
