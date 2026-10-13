defmodule Hermitscale.Support.Case do
  @moduledoc "An investigation anchored to a verified mapping and served revision."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "support_cases" do
    field :org_id, :string
    field :subscription_id, :binary_id
    field :initiator_user_id, :string
    field :operation_key, :string
    field :ticket_id, :string
    field :session_id, :binary_id
    field :deployed_revision, :string
    field :reply, :map
    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs),
    do:
      record
      |> cast(attrs, [:operation_key, :ticket_id])
      |> validate_required([
        :org_id,
        :subscription_id,
        :initiator_user_id,
        :operation_key,
        :ticket_id,
        :session_id
      ])
      |> unique_constraint([:org_id, :operation_key])
end
