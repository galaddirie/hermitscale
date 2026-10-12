defmodule Hermitscale.Workflows.Engine.Metadata do
  @moduledoc """
  Durable item correlation and local upstream history carried by Runic facts.

  Runtime resources never belong here. Equal payloads retain their individual
  occurrence IDs; histories merge by occurrence, rather than by value.
  """

  alias Runic.Identity
  alias Runic.Workflow.Fact

  @authority_keys ~w(credentials credential_ref execution_context actor_user_id execution_actor_user_id scope owner)
  @runtime_structs [
    Hermitscale.Integrations.CredentialRef,
    Hermitscale.Integrations.ExecutionContext,
    Hermitscale.Accounts.Scope,
    Hermitscale.Workflows.Engine.Context,
    Runic.Workflow.SingleOutput.Context,
    Runic.Workflow.CausalContext,
    Runic.Workflow
  ]

  @doc "Checks error terms without rejecting harmless exception structs or business reasons."
  def runtime_resources?(%module{}) when module in @runtime_structs, do: true

  def runtime_resources?(value)
      when is_pid(value) or is_reference(value) or is_port(value) or is_function(value),
      do: true

  def runtime_resources?(map) when is_map(map) do
    map
    |> Map.to_list()
    |> Enum.any?(fn {key, value} -> runtime_resources?(key) or runtime_resources?(value) end)
  end

  def runtime_resources?(list) when is_list(list), do: Enum.any?(list, &runtime_resources?/1)

  def runtime_resources?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> runtime_resources?()

  def runtime_resources?(_value), do: false

  def initialize(%Fact{hash: id, meta: metadata}) do
    case Map.fetch(metadata, :hermitscale) do
      {:ok, _state} ->
        validate!(metadata)

      :error ->
        put_state(metadata, %{root: id, frames: [], history: %{}, status: :ok, parents: [id]})
    end
  end

  def state(metadata), do: Map.fetch!(metadata, :hermitscale)

  def put_state(metadata, state) do
    metadata
    |> Map.put(:hermitscale, state)
    |> validate!()
  end

  def record(metadata, node_id, value, output_id) do
    state = state(metadata)

    entry = %{
      "json" => value,
      "occurrence" => output_id,
      "root" => state.root,
      "ancestry" => state.frames
    }

    put_state(metadata, %{state | history: Map.put(state.history, node_id, entry)})
  end

  def merge([first | rest]) do
    Enum.reduce(rest, first, fn metadata, acc ->
      left = state(acc)
      right = state(metadata)

      if left.root != right.root do
        raise ArgumentError, "cannot merge metadata from unrelated workflow inputs"
      end

      history = Map.merge(left.history, right.history, fn _id, a, b -> merge_history(a, b) end)

      merged = %{
        left
        | frames: common_frames(left.frames, right.frames),
          history: history,
          parents: Enum.uniq(left.parents ++ right.parents)
      }

      acc
      |> Map.merge(Map.delete(metadata, :hermitscale))
      |> put_state(merged)
    end)
  end

  def validate!(metadata) when is_map(metadata) and not is_struct(metadata) do
    assert_data!(metadata)

    %{root: root, frames: frames, history: history, status: status, parents: parents} =
      state(metadata)

    unless is_list(frames) and is_map(history) and status in [:ok, :empty, :skipped] and
             is_list(parents) do
      raise ArgumentError, "invalid workflow correlation metadata"
    end

    validate_id!(root)
    Enum.each(frames, &validate_frame!/1)
    Enum.each(parents, &validate_id!/1)

    Enum.each(history, fn {node, entries} ->
      unless is_binary(node), do: raise(ArgumentError, "upstream history keys must be node IDs")
      Enum.each(List.wrap(entries), &validate_entry!/1)
    end)

    metadata |> Map.delete(:hermitscale) |> assert_control!()
    metadata |> state() |> Map.drop([:frames, :history, :collected, :joined]) |> assert_control!()
    metadata
  end

  def validate!(_metadata), do: raise(ArgumentError, "workflow metadata must be a plain map")

  defp merge_history(a, b) do
    (List.wrap(a) ++ List.wrap(b))
    |> Enum.reduce({%{}, []}, fn entry, {seen, entries} ->
      id = Map.fetch!(entry, "occurrence")

      case Map.fetch(seen, id) do
        :error -> {Map.put(seen, id, entry), [entry | entries]}
        {:ok, ^entry} -> {seen, entries}
        {:ok, _other} -> raise ArgumentError, "conflicting values for an upstream occurrence"
      end
    end)
    |> elem(1)
    |> Enum.reverse()
    |> case do
      [single] -> single
      entries -> entries
    end
  end

  defp common_frames([same | left], [same | right]), do: [same | common_frames(left, right)]
  defp common_frames(_left, _right), do: []

  defp validate_frame!(%{map: map, batch: batch, item: item, index: index, size: size, value: _})
       when is_binary(map) and is_integer(index) and index >= 0 and is_integer(size) and size >= 0 and
              ((size == 0 and index == 0) or index < size) do
    validate_id!(batch)
    validate_id!(item)
  end

  defp validate_frame!(_frame), do: raise(ArgumentError, "invalid map lineage frame")

  defp validate_entry!(%{
         "json" => _value,
         "occurrence" => id,
         "root" => root,
         "ancestry" => frames
       })
       when is_list(frames) do
    validate_id!(id)
    validate_id!(root)
    Enum.each(frames, &validate_frame!/1)
  end

  defp validate_entry!(_entry), do: raise(ArgumentError, "invalid upstream occurrence")

  defp validate_id!(%Identity{
         domain: :fact_occurrence,
         scheme: :sha256,
         version: 1,
         digest: digest
       })
       when is_binary(digest) and byte_size(digest) == 32,
       do: :ok

  defp validate_id!(_id),
    do: raise(ArgumentError, "lineage coordinates require fact occurrence IDs")

  defp assert_control!(%Identity{}), do: :ok

  defp assert_control!(map) when is_map(map) do
    Enum.each(map, fn {key, value} ->
      if (is_atom(key) or is_binary(key)) and to_string(key) in @authority_keys do
        raise ArgumentError, "runtime authority cannot be stored in workflow metadata"
      end

      assert_control!(value)
    end)
  end

  defp assert_control!(list) when is_list(list), do: Enum.each(list, &assert_control!/1)
  defp assert_control!(_value), do: :ok

  defp assert_data!(%Identity{}), do: :ok

  defp assert_data!(value)
       when is_struct(value) or is_pid(value) or is_reference(value) or is_port(value) or
              is_function(value) do
    raise ArgumentError, "workflow metadata cannot retain runtime resources or authority"
  end

  defp assert_data!(map) when is_map(map) do
    Enum.each(map, fn {key, value} ->
      assert_data!(key)
      assert_data!(value)
    end)
  end

  defp assert_data!(list) when is_list(list), do: Enum.each(list, &assert_data!/1)
  defp assert_data!(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> assert_data!()
  defp assert_data!(_value), do: :ok
end
