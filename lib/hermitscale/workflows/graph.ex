defmodule Hermitscale.Workflows.Graph do
  @moduledoc """
  Stored user-composed workflow graph definition.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "workflow_graphs" do
    field :schema_version, :integer, default: 1
    field :name, :string
    field :definition, :map
    field :status, Ecto.Enum, values: [:draft, :active, :archived], default: :draft
    field :validation_issues, {:array, :map}, default: []
    field :validated_at, :utc_datetime

    has_many :runs, Hermitscale.Workflows.Run, foreign_key: :workflow_graph_id

    timestamps(type: :utc_datetime)
  end

  def changeset(graph, attrs) do
    graph
    |> cast(attrs, [
      :id,
      :schema_version,
      :name,
      :definition,
      :status,
      :validation_issues,
      :validated_at
    ])
    |> validate_required([:id, :schema_version, :name, :definition, :status])
    |> validate_format(:id, ~r/^[A-Za-z][A-Za-z0-9_:-]*$/)
    |> validate_number(:schema_version, greater_than: 0)
  end

  def put_validation_issues(changeset, issues) do
    changeset
    |> put_change(:validation_issues, Enum.map(issues, &Map.from_struct/1))
    |> add_error(:definition, "is not a valid workflow graph")
  end
end
