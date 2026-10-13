defmodule Hermitscale.Workflows.Graph do
  @moduledoc """
  Stored user-composed workflow graph definition.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Hermitscale.Accounts.Scope

  @editable_fields [
    :schema_version,
    :name,
    :definition,
    :status
  ]

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "workflow_graphs" do
    field :org_id, :string
    field :created_by_user_id, :string
    field :operation_key, :string
    field :admission_digest, :string

    field :schema_version, :integer, default: 1
    field :name, :string
    field :definition, :map
    field :status, Ecto.Enum, values: [:draft, :active, :archived], default: :draft
    field :validation_issues, {:array, :map}, default: []
    field :validated_at, :utc_datetime

    has_many :runs, Hermitscale.Workflows.Run, foreign_key: :workflow_graph_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def create_changeset(graph, attrs, %Scope{user: %{id: user_id}} = scope) do
    org_id = Scope.organization_id!(scope)

    graph
    |> cast(attrs, [:id | @editable_fields])
    |> put_change(:org_id, org_id)
    |> put_change(:created_by_user_id, user_id)
    |> validate_authoring()
    |> validate_required([:created_by_user_id])
    |> unique_constraint(:id, name: :workflow_graphs_pkey)
    |> unique_constraint([:org_id, :created_by_user_id, :operation_key])
  end

  @doc false
  def update_changeset(graph, attrs) do
    graph
    |> cast(attrs, @editable_fields)
    |> validate_authoring()
  end

  defp validate_authoring(changeset) do
    changeset
    |> validate_required([:id, :org_id, :schema_version, :name, :definition, :status])
    |> validate_format(:id, ~r/^[A-Za-z][A-Za-z0-9_:-]*$/)
    |> validate_number(:schema_version, greater_than: 0)
  end

  @doc false
  def status_changeset(graph, attrs) do
    graph
    |> cast(attrs, [:status])
    |> validate_required([:status])
  end

  def put_validation_issues(changeset, issues) do
    changeset
    |> put_change(:validation_issues, Enum.map(issues, &Map.from_struct/1))
    |> add_error(:definition, "is not a valid workflow graph")
  end
end
