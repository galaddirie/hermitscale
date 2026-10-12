defmodule Hermitscale.Workflows.Topology do
  @moduledoc """
  Structural relationships and deterministic ordering for workflow graphs.

  Operates on graph shapes and endpoints already checked by `Validator`.
  """

  def parent_map(connections) do
    connections
    |> Enum.group_by(&Map.fetch!(&1, "to"))
    |> Map.new(fn {to, edges} ->
      parents =
        edges
        |> Enum.sort_by(&Map.get(&1, "to_input", 0))
        |> Enum.map(&Map.fetch!(&1, "from"))

      {to, parents}
    end)
  end

  def child_map(connections),
    do: Enum.group_by(connections, &Map.fetch!(&1, "from"), &Map.fetch!(&1, "to"))

  def ancestor_map(nodes, connections) do
    parents = parent_map(connections)

    Map.new(nodes, fn %{"id" => id} ->
      {id, collect_ancestors(id, parents, MapSet.new())}
    end)
  end

  def order(%{"nodes" => nodes, "connections" => connections}) do
    ids = Enum.map(nodes, &Map.fetch!(&1, "id"))
    parents = parent_map(connections)
    children = child_map(connections)
    incoming_counts = Map.new(ids, &{&1, length(Map.get(parents, &1, []))})

    queue =
      ids
      |> Enum.filter(&(Map.fetch!(incoming_counts, &1) == 0))
      |> :queue.from_list()

    sorted = do_order(queue, incoming_counts, children, [])

    if length(sorted) == length(ids), do: {:ok, sorted}, else: {:error, :cycle}
  end

  defp collect_ancestors(id, parents, seen) do
    parents
    |> Map.get(id, [])
    |> Enum.reduce(seen, fn parent, seen ->
      if MapSet.member?(seen, parent) do
        seen
      else
        collect_ancestors(parent, parents, MapSet.put(seen, parent))
      end
    end)
  end

  defp do_order(queue, incoming_counts, children, sorted) do
    case :queue.out(queue) do
      {{:value, id}, queue} ->
        {queue, incoming_counts} =
          children
          |> Map.get(id, [])
          |> Enum.reduce({queue, incoming_counts}, &enqueue_child/2)

        do_order(queue, incoming_counts, children, [id | sorted])

      {:empty, _queue} ->
        Enum.reverse(sorted)
    end
  end

  defp enqueue_child(child, {queue, incoming_counts}) do
    count = Map.fetch!(incoming_counts, child) - 1
    queue = if count == 0, do: :queue.in(child, queue), else: queue
    {queue, Map.put(incoming_counts, child, count)}
  end
end
