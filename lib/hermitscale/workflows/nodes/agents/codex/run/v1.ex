defmodule Hermitscale.Workflows.Nodes.Agents.Codex.Run.V1 do
  @moduledoc "Runs a retained coding conversation and waits for its terminal result."
  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "agents.codex.run",
    version: 1,
    kind: :step,
    requires: [execution_context: []],
    expr: [:instructions, :session_id, :repository, :base_sha, :app_id],
    params: [
      instructions: [type: :string, required: true],
      session_id: [type: :string],
      repository: [type: :string],
      base_sha: [type: :string],
      app_id: [type: :string],
      title: [type: :string, default: "Workflow coding task"],
      connection_set: [type: :map, default: %{}],
      result_schema: [type: :map, default: %{}],
      verification_commands: [type: {:list, :string}, default: []],
      timeout_seconds: [type: :pos_integer, default: 900]
    ]

  alias Hermitscale.{Agents, Apps, Authorization}
  alias Runic.Workflow.SingleOutput.Result

  @impl true
  def work(params, _item, %{execution_context: identity, context: context}) do
    key =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({context.root_id, context.activation_id}, [:deterministic])
      )
      |> Base.encode16(case: :lower)

    with {:ok, scope} <- Authorization.execution_scope(identity),
         {:ok, session} <- coding_session(scope, params, key),
         {:ok, turn} <-
           Agents.submit_turn(scope, session.id, Map.put(params, :operation_key, key)),
         {:ok, turn} <- Agents.await_turn(scope, turn.id) do
      case turn.status do
        :succeeded ->
          result = if is_map(turn.result), do: turn.result, else: %{"result" => turn.result}

          Map.merge(result, %{
            "turn_id" => turn.id,
            "session_id" => session.id,
            "workspace_id" => session.workspace_id,
            "outcome" => "succeeded"
          })

        status when status in [:failed, :interrupted, :cancelled] ->
          Result.failure(%{"reason" => "agent_turn_#{status}", "details" => turn.error})
      end
    else
      {:error, reason} -> Result.failure(reason)
    end
  end

  defp coding_session(scope, %{session_id: id}, _key), do: Agents.get_session(scope, id)

  defp coding_session(scope, %{app_id: id} = params, _key),
    do: Apps.start_build(scope, id, params)

  defp coding_session(scope, params, key),
    do: Agents.start_session(scope, Map.put(params, :operation_key, key))

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

      params.timeout_seconds not in 30..3600 ->
        {:error, "timeout_seconds must be between 30 and 3600"}

      Hermitscale.Agents.Result.validate_schema(params.result_schema) != :ok ->
        {:error, "result_schema must be a supported JSON schema"}

      true ->
        :ok
    end
  end
end
