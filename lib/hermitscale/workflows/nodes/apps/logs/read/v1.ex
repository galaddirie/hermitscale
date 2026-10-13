defmodule Hermitscale.Workflows.Nodes.Apps.Logs.Read.V1 do
  @moduledoc "Reads native Sprite service output on request."
  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "apps.logs.read",
    version: 1,
    kind: :step,
    requires: [execution_context: []],
    expr: [:app_id],
    params: [app_id: [type: :string, required: true], limit: [type: :pos_integer, default: 100]]

  @impl true
  def work(params, _item, %{execution_context: identity}) do
    with {:ok, scope} <- Hermitscale.Authorization.execution_scope(identity),
         {:ok, logs} <- Hermitscale.Apps.read_logs(scope, params.app_id, limit: params.limit) do
      %{"logs" => logs}
    else
      {:error, reason} -> Runic.Workflow.SingleOutput.Result.failure(reason)
    end
  end
end
