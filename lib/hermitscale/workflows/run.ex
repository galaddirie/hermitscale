defmodule Hermitscale.Workflows.Run do
  @moduledoc """
  Queryable control-plane record for one workflow execution.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "workflow_runs" do
    field :status, Ecto.Enum,
      values: [:created, :running, :complete, :failed, :cancelled],
      default: :created

    field :initiated_by_user_id, :string
    field :execution_actor_user_id, :string
    field :trigger_id, :string
    field :account_selections, :map, default: %{}
    field :definition, :map
    field :admission_digest, :string

    field :owner, :string
    field :lease_expires_at, :utc_datetime
    field :last_event_sequence, :integer, default: 0
    field :input, :map
    field :output, :map
    field :error, :map
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :graph, Hermitscale.Workflows.Graph, foreign_key: :workflow_graph_id
    has_many :events, Hermitscale.Workflows.RunEvent

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :id,
      :workflow_graph_id,
      :definition,
      :status,
      :owner,
      :lease_expires_at,
      :last_event_sequence,
      :input,
      :output,
      :error,
      :started_at,
      :completed_at
    ])
    |> validate_required([:id, :status, :last_event_sequence])
    |> validate_number(:last_event_sequence, greater_than_or_equal_to: 0)
    |> validate_execution_actor()
    |> foreign_key_constraint(:workflow_graph_id)
    |> foreign_key_constraint(:trigger_id)
  end

  defp validate_execution_actor(changeset) do
    case get_field(changeset, :workflow_graph_id) do
      nil -> changeset
      _id -> validate_required(changeset, [:execution_actor_user_id])
    end
  end
end
