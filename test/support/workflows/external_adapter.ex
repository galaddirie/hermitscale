defmodule Hermitscale.WorkflowExternalTest.Adapter do
  @moduledoc false
  @behaviour Hermitscale.Workflows.ExternalOperationAdapter
  alias Hermitscale.Workflows.ExternalOperationAdapter

  @impl true
  def dispatch(_scope, %{node_type: type} = operation)
      when type in ["agents.codex.run", "agents.publish_branch"] do
    send(self(), {:external_dispatch, operation.node_type, operation.id, operation.request})
    {:waiting, %{"kind" => "test", "id" => operation.id}}
  end

  def dispatch(scope, operation), do: ExternalOperationAdapter.dispatch(scope, operation)

  @impl true
  def poll(_scope, %{resource: %{"kind" => "test"} = resource}), do: {:waiting, resource}
  def poll(scope, operation), do: ExternalOperationAdapter.poll(scope, operation)
end
