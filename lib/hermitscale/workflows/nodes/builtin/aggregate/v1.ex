defmodule Hermitscale.Workflows.Nodes.Builtin.Aggregate.V1 do
  @moduledoc """
  Closes the innermost map and collects surviving items in their source order.

  The optional `value` expression transforms each item with the same contextual
  bindings as an ordinary node. Empty collections produce `[]`; explicitly
  skipped items are omitted. Nested collection payloads keep their shape.
  """

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "aggregate",
    version: 1,
    kind: :aggregate,
    expr: [:value],
    params: [value: [type: :any, default: nil, doc: "Optional per-item expression."]]

  @impl true
  def work(%{value: nil}, item, _deps), do: item
  def work(%{value: value}, _item, _deps), do: value
end
