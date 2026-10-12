defmodule Hermitscale.Workflows.Engine.Context do
  @moduledoc """
  The transient callback view of one item and one execution attempt.

  `item` is the original innermost mapped item; `json` is its current value.
  `ancestry` lists the enclosing map frames from outermost to innermost.
  Runtime resources remain separate from the durable metadata and from the
  expression namespaces.
  """

  alias Hermitscale.Workflows.Engine.Metadata
  alias Hermitscale.Workflows.Expr
  alias Runic.Identity

  defstruct [
    :item,
    :json,
    :item_index,
    :input_id,
    :root_id,
    :runnable_id,
    :activation_id,
    :attempt_id,
    :attempt_number,
    ancestry: [],
    upstream: %{},
    execution: %{},
    runtime: %{}
  ]

  def new(value, metadata, callback_context, input_id) do
    state = Metadata.state(metadata)
    frame = List.last(state.frames)
    runtime = callback_context.runtime
    expression_runtime = Map.get(runtime, :_expr, %{})

    execution =
      expression_runtime
      |> Map.get(:execution, Map.get(expression_runtime, "execution", %{}))
      |> Map.merge(%{
        "input_id" => identity_string(input_id),
        "root_id" => identity_string(state.root),
        "runnable_id" => identity_string(callback_context.runnable_id),
        "activation_id" => identity_string(callback_context.activation_id),
        "attempt_id" => identity_string(callback_context.attempt_id),
        "attempt_number" => callback_context.attempt_number
      })

    %__MODULE__{
      item: if(frame, do: frame.value, else: value),
      json: value,
      item_index: if(frame, do: frame.index),
      input_id: input_id,
      root_id: state.root,
      runnable_id: callback_context.runnable_id,
      activation_id: callback_context.activation_id,
      attempt_id: callback_context.attempt_id,
      attempt_number: callback_context.attempt_number,
      ancestry: state.frames,
      upstream: state.history,
      execution: execution,
      runtime: runtime
    }
  end

  def expressions(%__MODULE__{} = context) do
    runtime = Map.get(context.runtime, :_expr, %{})

    %{"json" => context.json, "node" => expression_history(context.upstream)}
    |> Expr.build_context(runtime)
    |> Map.merge(%{
      "item" => context.item,
      "itemIndex" => context.item_index,
      "ancestry" => Enum.map(context.ancestry, &expression_frame/1),
      "execution" => context.execution
    })
  end

  defp expression_history(history) do
    Map.new(history, fn {node, entries} ->
      {node, map_entries(entries, &expression_entry/1)}
    end)
  end

  defp map_entries(entries, fun) when is_list(entries), do: Enum.map(entries, fun)
  defp map_entries(entry, fun), do: fun.(entry)

  defp expression_entry(entry) do
    entry
    |> Map.update!("occurrence", &identity_string/1)
    |> Map.update!("root", &identity_string/1)
    |> Map.update!("ancestry", fn frames -> Enum.map(frames, &expression_frame/1) end)
  end

  defp expression_frame(frame) do
    frame
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.update!("batch", &identity_string/1)
    |> Map.update!("item", &identity_string/1)
  end

  defp identity_string(%Identity{} = id), do: to_string(id)
  defp identity_string(nil), do: nil
end
