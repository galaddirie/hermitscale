defmodule Hermitscale.Workflows.Nodes.CollectionValue.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "test.collection_value",
    version: 1,
    kind: :step,
    expr: [:value, :skip],
    predicate: [:skip],
    params: [
      value: [type: :any, default: "{{ $json }}"],
      skip: [type: :boolean, default: false],
      fail: [type: :boolean, default: false]
    ]

  alias Runic.Workflow.SingleOutput.Result

  @impl true
  def work(%{fail: true}, _item, _deps), do: Result.failure(:fixture_failure)
  def work(%{skip: true}, _item, _deps), do: {:skip, :fixture_skip}
  def work(%{value: value}, _item, _deps), do: value
end
