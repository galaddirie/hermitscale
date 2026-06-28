defmodule Hermitscale.Workflows.Nodes.Params do
  @moduledoc """
  Validates and normalizes raw graph params against a node params schema.
  """

  @doc """
  Casts string-keyed graph params into a validated, atom-keyed map.

  Only schema-declared keys are considered. The output atoms all come from the
  schema, so user-controlled keys never become atoms.
  """
  def cast(raw, %NimbleOptions{schema: schema}), do: cast(raw, schema)

  def cast(raw, schema) when is_map(raw) and is_list(schema) do
    options =
      for {field, _opts} <- schema,
          key = Atom.to_string(field),
          Map.has_key?(raw, key) do
        {field, Map.fetch!(raw, key)}
      end

    case NimbleOptions.validate(options, schema) do
      {:ok, validated} -> {:ok, Map.new(validated)}
      {:error, %NimbleOptions.ValidationError{} = error} -> {:error, error}
    end
  end

  def cast!(raw, schema) do
    case cast(raw, schema) do
      {:ok, params} -> params
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end
end
