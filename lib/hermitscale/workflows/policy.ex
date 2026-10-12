defmodule Hermitscale.Workflows.Policy do
  @moduledoc false

  @enums %{
    backoff: %{
      "none" => :none,
      "linear" => :linear,
      "exponential" => :exponential,
      "jitter" => :jitter
    },
    on_failure: %{"halt" => :halt, "skip" => :skip}
  }
  @integer_keys [:max_retries, :base_delay_ms, :max_delay_ms, :timeout_ms, :deadline_ms]

  @key_atoms Map.new(Map.keys(@enums) ++ @integer_keys, &{Atom.to_string(&1), &1})

  def known_keys, do: Map.keys(@key_atoms)
  def integer_keys, do: Enum.map(@integer_keys, &Atom.to_string/1)

  def enum_values,
    do: Map.new(@enums, fn {key, values} -> {Atom.to_string(key), Map.keys(values)} end)

  @doc """
  Translates a string- or atom-keyed policy map into Runic's atom form,
  raising on unknown keys or invalid values.
  """
  def normalize(policy) when is_map(policy) do
    Map.new(policy, fn {key, value} ->
      normalize_pair(Map.fetch!(@key_atoms, to_string(key)), value)
    end)
  end

  @doc "Keeps skipped attempts as durable item outcomes for graph and runtime policies."
  def execution(%{on_failure: :skip} = policy) do
    case Map.get(policy, :fallback) do
      nil ->
        Map.merge(policy, %{
          on_failure: :halt,
          fallback: &Hermitscale.Workflows.Engine.Node.skip_failure/2
        })

      fallback when is_function(fallback) ->
        policy
    end
  end

  def execution(policy) when is_map(policy), do: policy

  defp normalize_pair(key, value)
       when key in @integer_keys and is_integer(value) and value >= 0,
       do: {key, value}

  defp normalize_pair(key, _value) when key in @integer_keys,
    do: raise(ArgumentError, "#{key} must be a non-negative integer")

  defp normalize_pair(key, value),
    do: {key, Map.fetch!(Map.fetch!(@enums, key), to_string(value))}
end
