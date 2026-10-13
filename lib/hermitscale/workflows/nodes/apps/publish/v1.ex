defmodule Hermitscale.Workflows.Nodes.Apps.Publish.V1 do
  @moduledoc "Starts the app's native Sprite service and enables its public URL."
  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "apps.publish",
    version: 1,
    kind: :step,
    requires: [execution_context: []],
    expr: [:app_id, :start_command, :port],
    params: [
      app_id: [type: :string, required: true],
      start_command: [type: :string],
      port: [type: :pos_integer]
    ]

  @impl true
  def work(params, _item, %{execution_context: identity}) do
    with {:ok, scope} <- Hermitscale.Authorization.execution_scope(identity),
         {:ok, app} <- Hermitscale.Apps.publish(scope, params.app_id, params) do
      Hermitscale.ProductJSON.encode(app)
    else
      {:error, reason} -> Runic.Workflow.SingleOutput.Result.failure(reason)
    end
  end
end
