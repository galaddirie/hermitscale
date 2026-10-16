defmodule Hermitscale.Apps.App do
  @moduledoc "A workspace's HTTP service published on the apps domain."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @reserved_slugs ~w(www api app apps admin auth login status)

  schema "workspace_apps" do
    field :org_id, :string
    field :slug, :string
    field :access, Ecto.Enum, values: [:org, :public], default: :org
    field :sprite_url, :string

    belongs_to :workspace, Hermitscale.Workspaces.Workspace, type: :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(app, attrs) do
    app
    |> cast(attrs, [:slug, :access])
    |> update_change(:slug, &String.downcase/1)
    |> validate_required([:id, :workspace_id, :org_id, :slug, :access, :sprite_url])
    |> validate_format(:slug, ~r/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/,
      message: "must be lowercase letters, digits, and inner hyphens"
    )
    |> validate_exclusion(:slug, @reserved_slugs, message: "is reserved")
    |> unique_constraint(:slug)
    |> unique_constraint(:workspace_id, message: "already has an app")
    |> check_constraint(:access, name: :access_must_be_known)
  end
end
