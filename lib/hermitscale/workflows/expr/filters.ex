defmodule Hermitscale.Workflows.Expr.Filters do
  @moduledoc """
  Curated Liquid filters available to workflow expressions.

  Solid's built-in filters are deliberately exposed through an explicit allowlist.
  Custom filters in this module provide the n8n-style helpers that Solid does not
  ship with.
  """

  @custom_filter_arities %{
    "eq" => [2],
    "from_json" => [1],
    "gt" => [2],
    "gte" => [2],
    "is_empty" => [1],
    "lt" => [2],
    "lte" => [2],
    "ne" => [2],
    "to_json" => [1],
    "to_number" => [1],
    "uuid" => [1]
  }

  @builtin_filter_arities %{
    "abs" => [1],
    "append" => [2],
    "at_least" => [2],
    "at_most" => [2],
    "capitalize" => [1],
    "ceil" => [1],
    "compact" => [1, 2],
    "concat" => [2],
    "date" => [2],
    "default" => [1, 2, 3],
    "divided_by" => [2],
    "downcase" => [1],
    "first" => [1],
    "floor" => [1],
    "join" => [1, 2],
    "last" => [1],
    "lstrip" => [1],
    "minus" => [2],
    "modulo" => [2],
    "plus" => [2],
    "prepend" => [2],
    "remove" => [2],
    "remove_first" => [2],
    "remove_last" => [2],
    "replace" => [2, 3],
    "replace_first" => [2, 3],
    "replace_last" => [3],
    "reverse" => [1],
    "round" => [1, 2],
    "rstrip" => [1],
    "size" => [1],
    "slice" => [2, 3],
    "sort" => [1],
    "sort_natural" => [1],
    "split" => [2],
    "strip" => [1],
    "times" => [2],
    "truncate" => [1, 2, 3],
    "truncatewords" => [1, 2, 3],
    "uniq" => [1],
    "upcase" => [1],
    "where" => [2, 3]
  }

  @allowed_filter_arities Map.merge(@builtin_filter_arities, @custom_filter_arities)

  @doc false
  def allowed_filter_names, do: Map.keys(@allowed_filter_arities)

  @doc false
  def allowed_filter?(name), do: Map.has_key?(@allowed_filter_arities, name)

  @doc false
  def valid_arity?(name, arity) do
    arity in Map.get(@allowed_filter_arities, name, [])
  end

  def to_json(value), do: Jason.encode!(value)

  def from_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, error} -> raise %Solid.ArgumentError{message: Exception.message(error)}
    end
  end

  def from_json(_value), do: raise(%Solid.ArgumentError{message: "from_json expects a string"})

  def to_number(value) when is_integer(value) or is_float(value), do: value
  def to_number(true), do: 1
  def to_number(false), do: 0
  def to_number(nil), do: nil

  def to_number(value) when is_binary(value) do
    value
    |> String.trim()
    |> parse_number()
  end

  def to_number(_value), do: raise(%Solid.ArgumentError{message: "to_number expects a scalar"})

  def is_empty(value) when value in [nil, false, ""], do: true
  def is_empty(value) when is_list(value), do: value == []
  def is_empty(value) when is_map(value), do: map_size(value) == 0
  def is_empty(_value), do: false

  def uuid(_value), do: Ecto.UUID.generate()

  def eq(value, expected), do: value == expected
  def ne(value, expected), do: value != expected
  def gt(value, expected), do: compare!(value, expected) == :gt
  def gte(value, expected), do: compare!(value, expected) in [:gt, :eq]
  def lt(value, expected), do: compare!(value, expected) == :lt
  def lte(value, expected), do: compare!(value, expected) in [:lt, :eq]

  defp parse_number(""), do: nil

  defp parse_number(value) do
    case Integer.parse(value) do
      {integer, ""} ->
        integer

      _other ->
        case Float.parse(value) do
          {float, ""} -> float
          _other -> raise %Solid.ArgumentError{message: "could not parse number"}
        end
    end
  end

  defp compare!(left, right) do
    {left, right} = normalize_comparable(left, right)

    cond do
      left > right -> :gt
      left < right -> :lt
      true -> :eq
    end
  rescue
    ArgumentError ->
      raise %Solid.ArgumentError{message: "values are not comparable"}
  end

  defp normalize_comparable(left, right)
       when (is_integer(left) or is_float(left)) and is_binary(right) do
    {left, to_number(right)}
  end

  defp normalize_comparable(left, right)
       when is_binary(left) and (is_integer(right) or is_float(right)) do
    {to_number(left), right}
  end

  defp normalize_comparable(left, right), do: {left, right}
end
