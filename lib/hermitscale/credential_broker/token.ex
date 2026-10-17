defmodule Hermitscale.CredentialBroker.Token do
  @moduledoc "A broker token's hash, workspace, acting member, and lifetime. The secret is never stored."

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "workspace_broker_tokens" do
    field :org_id, :string
    field :actor_user_id, :string
    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :workspace, Hermitscale.Workspaces.Workspace, type: :string

    timestamps(type: :utc_datetime)
  end
end
