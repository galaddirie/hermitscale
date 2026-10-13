defmodule Hermitscale.Reviews.Review do
  @moduledoc "An expiring decision bound to an exact action and digest."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "reviews" do
    field :org_id, :string
    field :requested_by_user_id, :string
    field :operation_key, :string
    field :action, :string
    field :target_digest, :string
    field :target, :map, default: %{}
    field :policy_revision, :integer, default: 1
    field :eligible_approver_ids, {:array, :string}
    field :expires_at, :utc_datetime
    field :status, Ecto.Enum, values: [:requested, :approved, :rejected], default: :requested
    field :decided_by_user_id, :string
    field :decided_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(review, attrs) do
    review
    |> cast(attrs, [
      :operation_key,
      :action,
      :target_digest,
      :target,
      :policy_revision,
      :eligible_approver_ids
    ])
    |> validate_required([
      :org_id,
      :requested_by_user_id,
      :operation_key,
      :action,
      :target_digest,
      :eligible_approver_ids,
      :expires_at
    ])
    |> validate_format(:target_digest, ~r/^[0-9a-f]{64}$/)
    |> validate_number(:policy_revision, greater_than: 0)
    |> validate_length(:action, min: 1, max: 128)
    |> validate_length(:operation_key, min: 1, max: 128)
    |> unique_constraint([:org_id, :operation_key])
  end
end
