defmodule Hermitscale.Agents.Session do
  @moduledoc "A private durable conversation; its workspace survives archival and closure."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agent_sessions" do
    field :org_id, :string
    field :initiator_user_id, :string
    field :title, :string
    field :repository, :string
    field :base_sha, :string
    field :recipe, :string, default: "codex-v1"
    field :status, Ecto.Enum, values: [:open, :archived, :closed], default: :open
    field :last_event_sequence, :integer, default: 0
    field :operation_key, :string
    field :app_id, :binary_id
    field :connection_set, :map, default: %{}
    field :openai_account_id, :string, virtual: true
    field :github_account_id, :string, virtual: true
    field :provider_conversation_id, :string
    belongs_to :workspace, Hermitscale.Workspaces.Workspace
    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :title,
      :repository,
      :base_sha,
      :recipe,
      :operation_key,
      :connection_set,
      :openai_account_id,
      :github_account_id
    ])
    |> selected_connections()
    |> update_change(:title, &String.trim/1)
    |> validate_required([:title, :org_id, :initiator_user_id, :recipe, :workspace_id])
    |> validate_length(:title, min: 1, max: 160)
    |> validate_format(:repository, ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/)
    |> validate_format(:base_sha, ~r/^[0-9a-f]{40}$/)
    |> validate_inclusion(:recipe, ["codex-v1", "python-sqlite-v1"])
    |> validate_source()
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint(:workspace_id)
    |> unique_constraint([:org_id, :initiator_user_id, :operation_key])
  end

  defp selected_connections(changeset) do
    Enum.reduce(
      [{"openai", :openai_account_id}, {"github", :github_account_id}],
      changeset,
      fn {provider, field}, cs ->
        case fetch_change(cs, field) do
          {:ok, id} when is_binary(id) and id != "" ->
            put_change(
              cs,
              :connection_set,
              Map.put(get_field(cs, :connection_set), provider, %{
                "provider" => provider,
                "account_id" => id
              })
            )

          _unchanged ->
            cs
        end
      end
    )
  end

  defp validate_source(changeset) do
    case get_field(changeset, :repository) do
      nil -> changeset
      _repository -> validate_required(changeset, [:base_sha])
    end
  end
end
