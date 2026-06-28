defmodule Hermitscale.Workflows.Template do
  @moduledoc """
  Constrained interpolation for workflow params.

  Supports only JSON-style accessors such as `{{ $.sku }}` and
  `{{ $.items.0.sku }}`. It never evaluates arbitrary code.
  """

  @interpolation ~r/\{\{\s*(\$\.[A-Za-z0-9_.-]+)\s*\}\}/

  @doc """
  Renders a template against an input map/list.
  """
  def render(template, input) when is_binary(template) do
    expressions =
      @interpolation
      |> Regex.scan(template, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    with {:ok, values} <- resolve_expressions(expressions, input) do
      rendered =
        Regex.replace(@interpolation, template, fn _full, expression ->
          Map.fetch!(values, expression)
        end)

      {:ok, rendered}
    end
  end

  @doc """
  Renders a template and raises on invalid paths.
  """
  def render!(template, input) do
    case render(template, input) do
      {:ok, rendered} -> rendered
      {:error, reason} -> raise ArgumentError, "invalid workflow template: #{inspect(reason)}"
    end
  end

  defp resolve_expressions(expressions, input) do
    Enum.reduce_while(expressions, {:ok, %{}}, fn expression, {:ok, acc} ->
      case resolve(expression, input) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, expression, stringify(value))}}
        {:error, reason} -> {:halt, {:error, {expression, reason}}}
      end
    end)
  end

  defp resolve("$." <> path, input) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce_while({:ok, input}, fn segment, {:ok, current} ->
      case fetch_segment(current, segment) do
        {:ok, value} -> {:cont, {:ok, value}}
        :error -> {:halt, {:error, {:missing_path, segment}}}
      end
    end)
  end

  defp fetch_segment(map, segment) when is_map(map) do
    case Map.fetch(map, segment) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        map
        |> Enum.find(fn {key, _value} -> is_atom(key) and Atom.to_string(key) == segment end)
        |> case do
          {_key, value} -> {:ok, value}
          nil -> :error
        end
    end
  end

  defp fetch_segment(list, segment) when is_list(list) do
    case Integer.parse(segment) do
      {index, ""} -> Enum.fetch(list, index)
      _other -> :error
    end
  end

  defp fetch_segment(_value, _segment), do: :error

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(value) when is_float(value), do: Float.to_string(value)
  defp stringify(value) when is_boolean(value), do: Atom.to_string(value)
  defp stringify(nil), do: ""
  defp stringify(value), do: Jason.encode!(value)
end
