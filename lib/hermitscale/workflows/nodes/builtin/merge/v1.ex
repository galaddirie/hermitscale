defmodule Hermitscale.Workflows.Nodes.Builtin.Merge.V1 do
  @moduledoc """
  Joins two upstream branches into one, waiting for both before emitting.

  The node receives its parents' values as an ordered list (`$json`). `mode`
  controls how they combine:

    * `"append"` — emit the ordered list `[left, right]` (the default).
    * `"combine"` — shallow-merge map inputs into one map (later inputs win).
  """

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "merge",
    version: 1,
    kind: :join,
    inputs: [:left, :right],
    outputs: [:main],
    params: [
      mode: [
        type: {:in, ["append", "combine"]},
        default: "append",
        doc: "How to combine the joined inputs: \"append\" (list) or \"combine\" (merged map)."
      ]
    ]

  @impl true
  def work(%{mode: "combine"}, inputs, _deps) when is_list(inputs) do
    Enum.reduce(inputs, %{}, fn
      input, acc when is_map(input) -> Map.merge(acc, input)
      _input, acc -> acc
    end)
  end

  def work(_params, inputs, _deps), do: inputs
end
