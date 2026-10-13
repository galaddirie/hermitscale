defmodule Hermitscale.ProductJSON do
  @moduledoc "Secret-free JSON representations at the product transport boundary."
  def encode(%Ecto.Changeset{} = cs),
    do: %{errors: Ecto.Changeset.traverse_errors(cs, fn {message, _} -> message end)}

  def encode(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def encode(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  def encode(%Ecto.Association.NotLoaded{}), do: nil

  def encode(%_{} = struct),
    do:
      struct
      |> Map.from_struct()
      |> Map.drop([:__meta__, :content, :token_digest, :connection, :credential, :sealed_session])
      |> encode()

  def encode(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), encode(v)} end)
  def encode(list) when is_list(list), do: Enum.map(list, &encode/1)
  def encode(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> encode()
  def encode(atom) when is_atom(atom) and atom not in [true, false, nil], do: Atom.to_string(atom)
  def encode(value), do: value
end
