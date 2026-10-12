defmodule Hermitscale.Workflows.Nodes.FailureContextProbe.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "test.failure_context_probe",
    version: 1,
    kind: :step,
    requires: [credentials: [], observer: []],
    params: [mode: [type: :string, required: true]]

  @impl true
  def work(%{mode: "credential_failure"}, _input, deps),
    do: Runic.Workflow.SingleOutput.Result.failure(deps.credentials)

  def work(%{mode: "context_match"}, _input, deps), do: raise(MatchError, term: deps.context)

  def work(%{mode: "safe_failure"}, _input, _deps),
    do: Runic.Workflow.SingleOutput.Result.failure({:rate_limited, 60})

  def work(%{mode: "safe_exception"}, _input, _deps),
    do: raise(ArgumentError, "invalid business record")
end
