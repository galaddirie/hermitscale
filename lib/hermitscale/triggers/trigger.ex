defmodule Hermitscale.Triggers.Trigger do
  @moduledoc """
  Activation record for one trigger node of an active workflow graph.

  The graph definition is the authoring source of truth; a trigger row is
  derived from it at activation time and carries the runtime-only state a
  firing source needs (webhook token, schedule bookkeeping, poll cursor).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @modes [:manual, :webhook, :schedule, :polling, :stream]

  schema "workflow_triggers" do
    field :node_id, :string
    field :type, :string
    field :version, :integer
    field :mode, Ecto.Enum, values: @modes
    field :config, :map, default: %{}
    field :webhook_token, :string
    field :schedule, :string
    field :next_fire_at, :utc_datetime
    field :cursor, :map
    field :status, Ecto.Enum, values: [:enabled, :disabled, :errored], default: :enabled
    field :error, :map

    belongs_to :graph, Hermitscale.Workflows.Graph, foreign_key: :workflow_graph_id

    has_many :firings, Hermitscale.Triggers.Firing, foreign_key: :trigger_id

    timestamps(type: :utc_datetime)
  end

  def modes, do: @modes

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [
      :id,
      :workflow_graph_id,
      :node_id,
      :type,
      :version,
      :mode,
      :config,
      :webhook_token,
      :schedule,
      :next_fire_at,
      :cursor,
      :status,
      :error
    ])
    |> validate_required([:id, :workflow_graph_id, :node_id, :type, :version, :mode, :status])
    |> validate_number(:version, greater_than: 0)
    |> unique_constraint([:workflow_graph_id, :node_id])
    |> unique_constraint(:webhook_token)
  end
end
