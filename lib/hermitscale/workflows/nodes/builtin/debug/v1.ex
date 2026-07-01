defmodule Hermitscale.Workflows.Nodes.Builtin.Debug.V1 do
  @moduledoc """
  Pass-through workflow debug node.

  Logs either one resolved value or each item from a resolved list, then returns
  the original input unchanged so it can be placed inline in a graph.
  """

  require Logger

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "debug",
    version: 1,
    kind: :step,
    inputs: [:main],
    outputs: [:main],
    expr: [:value],
    params: [
      label: [type: :string, default: "debug", doc: "Label attached to debug log entries."],
      mode: [
        type: {:in, ["input", "each"]},
        default: "input",
        doc: "Whether to log the resolved value once or once per item."
      ],
      value: [type: :any, default: nil, doc: "Optional expression-resolved value to log."]
    ]

  @impl true
  def work(%{label: label, mode: "input", value: nil}, input, _deps) do
    log_value(label, input)
    input
  end

  def work(%{label: label, mode: "input", value: value}, input, _deps) do
    log_value(label, value)
    input
  end

  def work(%{label: label, mode: "each", value: nil}, input, _deps) do
    log_each(label, input)
    input
  end

  def work(%{label: label, mode: "each", value: value}, input, _deps) do
    log_each(label, value)
    input
  end

  defp log_each(label, values) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.each(fn {value, index} -> log_value(label, value, index) end)
  end

  defp log_each(label, value), do: log_value(label, value, 0)

  defp log_value(label, value) do
    Logger.info("Workflow debug",
      workflow_debug_label: label,
      workflow_debug_value: inspect(value, limit: :infinity)
    )
  end

  defp log_value(label, value, index) do
    Logger.info("Workflow debug",
      workflow_debug_label: label,
      workflow_debug_index: index,
      workflow_debug_value: inspect(value, limit: :infinity)
    )
  end
end
