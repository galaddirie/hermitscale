defmodule Hermitscale.CredentialBroker.Grant do
  @moduledoc """
  Attaches one organization connected account to a workspace for one provider.

  Each rule is `"<METHOD> <path>"`. The method is an HTTP method, `FETCH` or
  `PUSH` for Git, or `*`. The path is exact, or a prefix when it ends with `*`.
  A request is allowed when any rule matches.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @rule ~r{^(\*|GET|HEAD|POST|PUT|PATCH|DELETE|FETCH|PUSH) /[^\s*]*\*?$}

  schema "workspace_credential_grants" do
    field :org_id, :string
    field :provider, :string
    field :account_id, :string
    field :rules, {:array, :string}
    field :created_by_user_id, :string

    belongs_to :workspace, Hermitscale.Workspaces.Workspace, type: :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:provider, :account_id, :rules])
    |> validate_required([
      :id,
      :workspace_id,
      :org_id,
      :provider,
      :account_id,
      :rules,
      :created_by_user_id
    ])
    |> validate_length(:rules, min: 1)
    |> validate_change(:rules, fn :rules, rules ->
      case Enum.reject(rules, &Regex.match?(@rule, &1)) do
        [] -> []
        invalid -> [rules: "has invalid rules: #{Enum.join(invalid, ", ")}"]
      end
    end)
    |> unique_constraint([:workspace_id, :provider])
  end

  @doc "Checks whether any rule allows the method on the decoded request path."
  def allows?(%__MODULE__{rules: rules}, method, path),
    do: Enum.any?(rules, &rule_matches?(&1, method, path))

  defp rule_matches?(rule, method, path) do
    [rule_method, pattern] = String.split(rule, " ", parts: 2)
    rule_method in ["*", method] and path_matches?(pattern, path)
  end

  defp path_matches?(pattern, path) do
    case String.split_at(pattern, -1) do
      {prefix, "*"} -> String.starts_with?(path, prefix)
      _exact -> pattern == path
    end
  end
end
