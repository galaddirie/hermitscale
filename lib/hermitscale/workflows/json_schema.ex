defmodule Hermitscale.Workflows.JsonSchema do
  @moduledoc """
  Minimal projection from NimbleOptions schemas to JSON Schema-like maps.
  """

  def from_nimble(schema) when is_list(schema) do
    properties =
      Map.new(schema, fn {field, opts} ->
        {Atom.to_string(field), option_schema(opts)}
      end)

    required =
      for {field, opts} <- schema, Keyword.get(opts, :required, false), do: Atom.to_string(field)

    %{
      type: "object",
      properties: properties,
      required: required
    }
  end

  defp option_schema(opts) do
    opts
    |> Keyword.get(:type, :any)
    |> type_schema()
    |> maybe_put_description(opts)
  end

  defp type_schema({:in, values}), do: %{enum: values}
  defp type_schema(:string), do: %{type: "string"}
  defp type_schema(:integer), do: %{type: "integer"}
  defp type_schema(:pos_integer), do: %{type: "integer", minimum: 1}
  defp type_schema(:non_neg_integer), do: %{type: "integer", minimum: 0}
  defp type_schema(:boolean), do: %{type: "boolean"}
  defp type_schema(:map), do: %{type: "object"}
  defp type_schema(:keyword_list), do: %{type: "object"}
  defp type_schema(:any), do: %{}
  defp type_schema(_type), do: %{}

  defp maybe_put_description(schema, opts) do
    case Keyword.get(opts, :doc) do
      nil -> schema
      doc -> Map.put(schema, :description, doc)
    end
  end
end
