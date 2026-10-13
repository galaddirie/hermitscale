defmodule Hermitscale.Workflows.Nodes.Agents.PublishBranch.V1 do
  @moduledoc "Commits the workspace changes and pushes the selected Git branch."
  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "agents.publish_branch",
    version: 1,
    kind: :step,
    requires: [execution_context: []],
    expr: [:session_id, :branch, :message],
    params: [
      session_id: [type: :string, required: true],
      branch: [type: :string, required: true],
      message: [type: :string, required: true]
    ]

  @impl true
  def work(params, _item, %{execution_context: identity, context: context}) do
    with {:ok, scope} <- Hermitscale.Authorization.execution_scope(identity),
         {:ok, result} <-
           Hermitscale.Agents.publish_branch(
             scope,
             params.session_id,
             Map.put(params, :operation_key, to_string(context.activation_id))
           ) do
      Hermitscale.ProductJSON.encode(result)
    else
      {:error, reason} -> Runic.Workflow.SingleOutput.Result.failure(reason)
    end
  end
end
