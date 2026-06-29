defmodule Hermitscale.Workflows.Nodes.Builtin.Map.V1 do
  @moduledoc """
  Fans the input list out and evaluates an expression once per element.

  Each element becomes `$json` for the `value` expression; the resolved value is
  emitted as that element's output. With no `value`, elements pass through
  unchanged. Use a downstream `reduce` to fold the results back together.
  """

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "map",
    version: 1,
    kind: :map,
    inputs: [:main],
    outputs: [:main],
    expr: [:value],
    params: [
      value: [
        type: :any,
        default: nil,
        doc: "Expression evaluated per element; may use {{ $json }} and {{ $node[...] }}."
      ]
    ]

  @impl true
  def work(%{value: nil}, element, _deps), do: element
  def work(%{value: value}, _element, _deps), do: value
end
