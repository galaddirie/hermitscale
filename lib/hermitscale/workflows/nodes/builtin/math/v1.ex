defmodule Hermitscale.Workflows.Nodes.Builtin.Math.V1 do
  @moduledoc """
  Per-item arithmetic node.

  When placed after a `map` node, this step runs once for each mapped item, so
  `left` and `right` expressions resolve against that current item as `$json`.
  """

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "math",
    version: 1,
    kind: :step,
    inputs: [:main],
    outputs: [:main],
    expr: [:left, :right],
    params: [
      operation: [
        type: {:in, ["add", "subtract", "multiply", "divide"]},
        required: true,
        doc: "Arithmetic operation to apply."
      ],
      left: [type: :any, required: true, doc: "Left operand or expression."],
      right: [type: :any, required: true, doc: "Right operand or expression."]
    ]

  @impl true
  def work(%{operation: "add", left: left, right: right}, _element, _deps),
    do: left + right

  def work(%{operation: "subtract", left: left, right: right}, _element, _deps),
    do: left - right

  def work(%{operation: "multiply", left: left, right: right}, _element, _deps),
    do: left * right

  def work(%{operation: "divide", left: left, right: right}, _element, _deps),
    do: left / right
end
