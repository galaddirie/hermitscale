defmodule Hermitscale.Credentials.CredentialEvent do
  @moduledoc """
  Append-only audit record for one credential lifecycle action.

  Carries identifiers and outcomes only — never secret material. `actor` is a
  user id, `"run:RUNID"`, or `"system"`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :string

  @actions [
    :created,
    :connected,
    :accessed,
    :refreshed,
    :rotated,
    :revoked,
    :reauth_required,
    :refresh_failed
  ]

  schema "credential_events" do
    field :action, Ecto.Enum, values: @actions
    field :actor, :string
    field :context, :map, default: %{}

    belongs_to :credential, Hermitscale.Credentials.Credential

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:credential_id, :action, :actor, :context])
    |> validate_required([:credential_id, :action, :actor])
    |> foreign_key_constraint(:credential_id)
  end
end
