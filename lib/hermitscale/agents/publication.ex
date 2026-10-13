defmodule Hermitscale.Agents.Publication do
  @moduledoc "A stable branch effect, reconciled before another push is considered."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "agent_publications" do
    field :org_id, :string
    field :session_id, :binary_id
    field :execution_actor_user_id, :string
    field :operation_key, :string
    field :payload_digest, :string
    field :specification, :map

    field :status, Ecto.Enum,
      values: [:queued, :running, :succeeded, :failed, :uncertain],
      default: :queued

    field :result, :map
    field :error, :map
    field :lease_id, :binary_id
    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:operation_key, :payload_digest, :specification])
    |> validate_required([
      :org_id,
      :session_id,
      :execution_actor_user_id,
      :operation_key,
      :payload_digest,
      :specification
    ])
    |> unique_constraint([:org_id, :operation_key])
  end
end
