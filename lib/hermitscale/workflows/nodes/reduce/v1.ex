defmodule Hermitscale.Workflows.Nodes.Reduce.V1 do
  @moduledoc """
  Folds the elements produced by an upstream `map` into a single accumulator.

  `initial` is a static seed (it cannot be an expression — the fold starts before
  any element arrives). For each element the `value` expression is evaluated with
  the current element as `$json` and the running accumulator as `$acc`; its result
  becomes the next accumulator. The final accumulator is the node's output.
  """

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "reduce",
    version: 1,
    kind: :reduce,
    inputs: [:main],
    outputs: [:main],
    expr: [:value],
    params: [
      initial: [type: :any, default: 0, doc: "Static seed accumulator (not an expression)."],
      value: [
        type: :any,
        default: nil,
        doc: "Fold expression evaluated per element; may use {{ $acc }} and {{ $json }}."
      ]
    ]

  @impl true
  def work(%{value: nil}, _element, %{acc: acc}), do: acc
  def work(%{value: value}, _element, _deps), do: value
end
