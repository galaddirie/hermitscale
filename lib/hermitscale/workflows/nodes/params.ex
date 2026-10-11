defmodule Hermitscale.Workflows.Nodes.Params do
  @moduledoc """
  Validates and normalizes raw graph params against a node params schema.
  """

  alias Hermitscale.Workflows.Expr

  @doc """
  Encodes compiler-created params for capture in a Runic closure.

  Compiled Solid templates are not canonical Runic identity values. Capturing
  their deterministic bytes keeps the compiled plan out of identity projection.
  These bindings are internal, version-coupled data, not an external input format.
  """
  @spec bind(map()) :: binary()
  def bind(params) when is_map(params) do
    assert_static!(params)
    :erlang.term_to_binary(params, [:deterministic])
  end

  @doc """
  Resolves an internal parameter binding against the current expression context.
  """
  @spec resolve!(binary(), map()) :: map()
  def resolve!(binding, context) when is_binary(binding) and is_map(context) do
    binding
    |> :erlang.binary_to_term([:safe])
    |> Expr.resolve!(context)
  end

  @doc """
  Casts string-keyed graph params into a validated, atom-keyed map.

  Only schema-declared keys are considered. The output atoms all come from the
  schema, so user-controlled keys never become atoms.
  """
  def cast(raw, %NimbleOptions{schema: schema}), do: cast(raw, schema)

  def cast(raw, schema) when is_map(raw) and is_list(schema) do
    cast(raw, schema, [])
  end

  def cast(raw, %NimbleOptions{schema: schema}, expr_fields), do: cast(raw, schema, expr_fields)

  def cast(raw, schema, expr_fields, predicate_fields \\ [])

  def cast(raw, schema, expr_fields, predicate_fields) when is_map(raw) and is_list(schema) do
    expr_fields = MapSet.new(expr_fields)
    predicate_fields = MapSet.new(predicate_fields)
    present_expr_fields = present_expr_fields(raw, schema, expr_fields)

    schema_for_validation =
      Enum.reject(schema, fn {field, _opts} -> MapSet.member?(present_expr_fields, field) end)

    options =
      for {field, _opts} <- schema_for_validation,
          key = Atom.to_string(field),
          Map.has_key?(raw, key) do
        {field, Map.fetch!(raw, key)}
      end

    case NimbleOptions.validate(options, schema_for_validation) do
      {:ok, validated} ->
        with {:ok, compiled} <- compile_expr_fields(raw, present_expr_fields, predicate_fields) do
          {:ok, Map.merge(Map.new(validated), compiled)}
        end

      {:error, %NimbleOptions.ValidationError{} = error} ->
        {:error, error}
    end
  end

  def cast!(raw, schema) do
    cast!(raw, schema, [])
  end

  def cast!(raw, schema, expr_fields, predicate_fields \\ []) do
    case cast(raw, schema, expr_fields, predicate_fields) do
      {:ok, params} -> params
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end

  defp assert_static!(value)
       when is_pid(value) or is_reference(value) or is_port(value) or is_function(value) do
    raise ArgumentError, "workflow parameter bindings cannot contain runtime-only values"
  end

  defp assert_static!(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.each(fn {key, leaf} ->
      assert_static!(key)
      assert_static!(leaf)
    end)
  end

  defp assert_static!(value) when is_list(value), do: Enum.each(value, &assert_static!/1)

  defp assert_static!(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> assert_static!()

  defp assert_static!(_value), do: :ok

  defp present_expr_fields(raw, schema, expr_fields) do
    schema
    |> Enum.map(fn {field, _opts} -> field end)
    |> Enum.filter(fn field ->
      MapSet.member?(expr_fields, field) and Map.has_key?(raw, Atom.to_string(field))
    end)
    |> MapSet.new()
  end

  defp compile_expr_fields(raw, present_expr_fields, predicate_fields) do
    Enum.reduce_while(present_expr_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      value = Map.fetch!(raw, Atom.to_string(field))
      opts = if MapSet.member?(predicate_fields, field), do: [predicate: true], else: []

      case Expr.compile_tree(value, opts) do
        {:ok, compiled} -> {:cont, {:ok, Map.put(acc, field, compiled)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
