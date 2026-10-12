defmodule Hermitscale.Workflows.Expr.Matcher do
  @moduledoc false

  def match(data, []), do: {:ok, data}

  def match(data, ["first" | keys]) when is_list(data), do: data |> List.first() |> match(keys)
  def match(data, ["last" | keys]) when is_list(data), do: data |> List.last() |> match(keys)
  def match(data, ["size" | keys]) when is_list(data), do: data |> length() |> match(keys)

  def match(data, [key | keys]) when is_list(data) and is_integer(key) do
    case Enum.fetch(data, key) do
      {:ok, value} -> match(value, keys)
      :error -> {:error, :not_found}
    end
  end

  def match(data, ["size" | keys]) when is_binary(data) do
    data
    |> String.length()
    |> match(keys)
  end

  def match(data, ["first" | keys]) when is_map(data) do
    data
    |> Enum.at(0)
    |> match(keys)
  end

  def match(data, ["size" | keys]) when is_map(data) do
    data
    |> map_size()
    |> match(keys)
  end

  def match(data, [key | keys]) when is_map(data) do
    case fetch_map(data, key) do
      {:ok, value} -> match(value, keys)
      :error -> {:error, :not_found}
    end
  end

  def match(data, ["size" | keys]) when is_tuple(data) do
    data
    |> tuple_size()
    |> match(keys)
  end

  def match(data, [key | keys])
      when is_tuple(data) and is_integer(key) and key >= 0 and key < tuple_size(data) do
    data
    |> elem(key)
    |> match(keys)
  end

  def match(nil, _keys), do: {:error, :not_found}
  def match(_data, _keys), do: {:error, :not_found}

  defp fetch_map(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} ->
        {:ok, value}

      :error when is_binary(key) ->
        fetch_atom_key(data, key)

      :error ->
        :error
    end
  end

  defp fetch_atom_key(data, key) do
    data
    |> Enum.find(fn
      {atom_key, _value} when is_atom(atom_key) -> Atom.to_string(atom_key) == key
      _entry -> false
    end)
    |> case do
      {_key, value} -> {:ok, value}
      nil -> :error
    end
  end
end
