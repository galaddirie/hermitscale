defmodule Hermitscale.Workflows.Nodes.Agents.Codex.Run.V1 do
  @moduledoc "Runs a retained coding conversation and waits for its verified terminal result."
  use Hermitscale.Workflows.Nodes.External,
    id: "agents.codex.run",
    version: 1,
    kind: :step,
    expr: [:instructions, :session_id, :repository, :base_sha, :app_id],
    params: [
      instructions: [type: :string, required: true],
      session_id: [type: :string],
      repository: [type: :string],
      base_sha: [type: :string],
      app_id: [type: :string],
      title: [type: :string, default: "Workflow coding task"],
      recipe: [type: :string, default: "codex-v1"],
      connection_set: [type: :map, default: %{}],
      result_schema: [type: :map, default: %{}],
      verification_commands: [type: {:list, :string}, default: []],
      budget_cents: [type: :pos_integer, default: 500],
      timeout_seconds: [type: :pos_integer, default: 900]
    ]

  @impl true
  def validate_params(%{connection_set: connections} = params) do
    valid? =
      Enum.all?(connections, fn {provider, selection} ->
        is_binary(provider) and
          Hermitscale.Integrations.ConnectedAccounts.validate_selection(selection, provider) ==
            :ok and
          not String.contains?(selection["account_id"], ["{{", "{%"])
      end)

    cond do
      not valid? ->
        {:error, "connection_set must contain fixed provider account selections"}

      params.budget_cents > 10_000 ->
        {:error, "budget_cents must not exceed 10000"}

      params.timeout_seconds not in 30..3600 ->
        {:error, "timeout_seconds must be between 30 and 3600"}

      Hermitscale.Agents.Result.validate_schema(params.result_schema) != :ok ->
        {:error, "result_schema must be a supported JSON schema"}

      true ->
        :ok
    end
  end
end
