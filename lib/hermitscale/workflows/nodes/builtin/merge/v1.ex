defmodule Hermitscale.Workflows.Nodes.Builtin.Merge.V1 do
  @moduledoc """
  Joins two branches of the same item occurrence, waiting for both terminal outcomes.

  The node receives its parents' values as an ordered list (`$json`). `mode`
  controls how they combine:

    * `"append"` — emit the ordered list `[left, right]` (the default).
    * `"combine"` — shallow-merge map inputs into one map (later inputs win).
    * `"zip_nil"` — zip list inputs, padding shorter inputs with nil.
    * `"zip_shortest"` — zip list inputs to the shortest length.
    * `"zip_cycle"` — zip to the longest length, cycling shorter inputs.
      Empty inputs contribute nil.
    * `"cartesian"` — every ordered combination of list input elements.
    * `"flatten"` — concatenate list inputs by one level.

  Collection modes operate on list payloads within the current occurrence;
  they never align unrelated map items. `on_missing` controls skipped branches:
  `"fail"` rejects missing inputs, `"nil"` preserves their slots with nil, and
  `"omit"` removes them before combining. Halting failures remain failures.
  """

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "merge",
    version: 1,
    kind: :join,
    inputs: [:left, :right],
    outputs: [:main],
    params: [
      mode: [
        type:
          {:in,
           ["append", "combine", "zip_nil", "zip_shortest", "zip_cycle", "cartesian", "flatten"]},
        default: "append",
        doc: "How to combine the joined inputs: \"append\" (list) or \"combine\" (merged map)."
      ],
      on_missing: [
        type: {:in, ["fail", "nil", "omit"]},
        default: "fail",
        doc: "How to handle an explicitly skipped input: fail, retain nil, or omit."
      ]
    ]

  @impl true
  def work(%{mode: "combine"}, inputs, _deps) when is_list(inputs) do
    Enum.reduce(inputs, %{}, fn
      input, acc when is_map(input) -> Map.merge(acc, input)
      _input, acc -> acc
    end)
  end

  def work(%{mode: "append"}, inputs, _deps), do: inputs

  def work(%{mode: mode}, inputs, _deps)
      when mode in ["zip_nil", "zip_shortest", "zip_cycle", "cartesian", "flatten"] do
    unless Enum.all?(inputs, &is_list/1) do
      raise ArgumentError, "collection join requires list inputs, got: #{inspect(inputs)}"
    end

    combine_collections(mode, inputs)
  end

  defp combine_collections("flatten", inputs), do: Enum.concat(inputs)

  defp combine_collections("cartesian", inputs) do
    Enum.reduce(inputs, [[]], fn values, rows ->
      for row <- rows, value <- values, do: row ++ [value]
    end)
  end

  defp combine_collections("zip_shortest", inputs), do: zip(inputs)

  defp combine_collections(mode, inputs) when mode in ["zip_nil", "zip_cycle"] do
    size = inputs |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    inputs
    |> Enum.map(&align(&1, size, mode))
    |> zip()
  end

  defp align([], size, _mode), do: List.duplicate(nil, size)
  defp align(values, size, "zip_nil"), do: values ++ List.duplicate(nil, size - length(values))
  defp align(values, size, "zip_cycle"), do: values |> Stream.cycle() |> Enum.take(size)

  defp zip(inputs), do: inputs |> Enum.zip() |> Enum.map(&Tuple.to_list/1)
end
