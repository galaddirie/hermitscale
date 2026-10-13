defmodule Hermitscale.Agents.Event do
  @moduledoc "Committed, bounded product history, ordered independently of a worker cursor."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agent_events" do
    field :org_id, :string
    belongs_to :session, Hermitscale.Agents.Session
    belongs_to :turn, Hermitscale.Agents.Turn
    field :sequence, :integer
    field :source_key, :string
    field :source_digest, :string
    field :type, :string
    field :payload, :map
    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:sequence, :source_key, :source_digest, :type, :payload])
    |> validate_required([
      :org_id,
      :session_id,
      :turn_id,
      :sequence,
      :source_key,
      :source_digest,
      :type,
      :payload
    ])
    |> validate_number(:sequence, greater_than: 0)
    |> unique_constraint([:session_id, :source_key])
    |> unique_constraint([:session_id, :sequence])
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:turn_id)
  end
end
