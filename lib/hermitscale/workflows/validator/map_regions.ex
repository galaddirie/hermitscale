defmodule Hermitscale.Workflows.Validator.MapRegions do
  @moduledoc false

  alias Hermitscale.Workflows.{Catalog, Expr, Topology}
  alias Hermitscale.Workflows.Nodes.Params
  alias Hermitscale.Workflows.Validator.Issue

  def issues(nodes, catalog, connections) do
    specs = catalog_specs_by_id(nodes, catalog)
    indexes = node_indexes(nodes)
    parents = Topology.parent_map(connections)
    children = Topology.child_map(connections)
    map_ids = ids_by_kind(specs, :map)
    reduce_ids = ids_by_kind(specs, :reduce)
    body_ids = map_body_ids(map_ids, specs, children)
    reduce_owners = map_reduce_owners(map_ids, specs, children)

    map_ids
    |> Enum.flat_map(&validate_map_region(&1, specs, parents, children, indexes, nodes, catalog))
    |> Kernel.++(
      Enum.flat_map(reduce_ids, &validate_reduce_owner(&1, reduce_owners, parents, indexes))
    )
    |> Kernel.++(map_region_reference_issues(nodes, catalog, body_ids, indexes))
  end

  defp catalog_specs_by_id(nodes, catalog) do
    Enum.reduce(nodes, %{}, fn
      %{"id" => id, "type" => type, "version" => version}, acc
      when is_binary(id) and is_binary(type) and is_integer(version) ->
        case Catalog.fetch(catalog, type, version) do
          {:ok, module} -> Map.put(acc, id, module.__catalog_node__())
          {:error, :not_found} -> acc
        end

      _node, acc ->
        acc
    end)
  end

  defp node_indexes(nodes) do
    nodes
    |> Enum.with_index()
    |> Map.new(fn {node, index} -> {node["id"], index} end)
  end

  defp ids_by_kind(specs, kind) do
    specs
    |> Enum.filter(fn {_id, spec} -> spec.kind == kind end)
    |> Enum.map(&elem(&1, 0))
  end

  defp validate_map_region(map_id, specs, parents, children, indexes, nodes, catalog) do
    case Map.get(children, map_id, []) do
      [] ->
        []

      [child] ->
        validate_map_region_node(
          child,
          specs,
          parents,
          children,
          indexes,
          nodes,
          catalog,
          MapSet.new([map_id])
        )

      region_children ->
        [
          Issue.new(
            node_path(indexes, map_id),
            :map_region_branch,
            "map regions must be linear before reduce; #{inspect(map_id)} has #{length(region_children)} downstream connections"
          )
        ]
    end
  end

  defp validate_map_region_node(id, specs, parents, children, indexes, nodes, catalog, seen) do
    if MapSet.member?(seen, id) do
      []
    else
      seen = MapSet.put(seen, id)
      parent_issues = validate_region_parent_count(id, parents, indexes)

      kind_issues =
        case node_kind(id, specs) do
          :reduce ->
            []

          :step ->
            region_step_reference_issues(id, nodes, catalog, indexes) ++
              validate_map_region_children(
                id,
                specs,
                parents,
                children,
                indexes,
                nodes,
                catalog,
                seen
              )

          kind ->
            [
              Issue.new(
                node_path(indexes, id),
                :unsupported_map_region_node,
                "map regions can contain only step nodes before reduce, got #{inspect(kind)} for #{inspect(id)}"
              )
            ]
        end

      parent_issues ++ kind_issues
    end
  end

  defp validate_map_region_children(id, specs, parents, children, indexes, nodes, catalog, seen) do
    case Map.get(children, id, []) do
      [] ->
        []

      [child] ->
        validate_map_region_node(child, specs, parents, children, indexes, nodes, catalog, seen)

      region_children ->
        [
          Issue.new(
            node_path(indexes, id),
            :map_region_branch,
            "map regions must be linear before reduce; #{inspect(id)} has #{length(region_children)} downstream connections"
          )
        ]
    end
  end

  defp validate_region_parent_count(id, parents, indexes) do
    case Map.get(parents, id, []) do
      [_parent] ->
        []

      region_parents ->
        [
          Issue.new(
            node_path(indexes, id),
            :map_region_parent_count,
            "map region node #{inspect(id)} must have exactly one structural parent, got #{length(region_parents)}"
          )
        ]
    end
  end

  defp validate_reduce_owner(id, reduce_owners, parents, indexes) do
    parent_issues =
      case Map.get(parents, id, []) do
        [_parent] ->
          []

        reduce_parents ->
          [
            Issue.new(
              node_path(indexes, id),
              :reduce_parent_count,
              "reduce node #{inspect(id)} must have exactly one structural parent, got #{length(reduce_parents)}"
            )
          ]
      end

    owner_issues =
      case Map.get(reduce_owners, id, []) do
        [_map] ->
          []

        [] ->
          [
            Issue.new(
              node_path(indexes, id),
              :reduce_without_map,
              "reduce node #{inspect(id)} must close exactly one upstream map region"
            )
          ]

        maps ->
          [
            Issue.new(
              node_path(indexes, id),
              :reduce_ambiguous_map,
              "reduce node #{inspect(id)} has multiple upstream map regions: #{inspect(maps)}"
            )
          ]
      end

    parent_issues ++ owner_issues
  end

  defp map_reduce_owners(map_ids, specs, children) do
    map_ids
    |> Enum.flat_map(fn map_id ->
      case map_reduce_id(map_id, specs, children) do
        nil -> []
        reduce_id -> [{reduce_id, map_id}]
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp map_reduce_id(map_id, specs, children) do
    case Map.get(children, map_id, []) do
      [child] -> collect_map_reduce_id(child, specs, children, MapSet.new([map_id]))
      _other -> nil
    end
  end

  defp collect_map_reduce_id(id, specs, children, seen) do
    cond do
      MapSet.member?(seen, id) ->
        nil

      node_kind(id, specs) == :reduce ->
        id

      node_kind(id, specs) == :step ->
        case Map.get(children, id, []) do
          [child] -> collect_map_reduce_id(child, specs, children, MapSet.put(seen, id))
          _other -> nil
        end

      true ->
        nil
    end
  end

  defp map_body_ids(map_ids, specs, children) do
    map_ids
    |> Enum.flat_map(&collect_map_body_ids(&1, specs, children))
    |> MapSet.new()
  end

  defp collect_map_body_ids(map_id, specs, children) do
    case Map.get(children, map_id, []) do
      [child] -> collect_map_body_node_ids(child, specs, children, [], MapSet.new([map_id]))
      _other -> []
    end
  end

  defp collect_map_body_node_ids(id, specs, children, ids, seen) do
    cond do
      MapSet.member?(seen, id) ->
        ids

      node_kind(id, specs) == :step ->
        case Map.get(children, id, []) do
          [child] ->
            collect_map_body_node_ids(child, specs, children, [id | ids], MapSet.put(seen, id))

          _other ->
            [id | ids]
        end

      true ->
        ids
    end
  end

  defp region_step_reference_issues(id, nodes, catalog, indexes) do
    node = Enum.find(nodes, &(&1["id"] == id))

    case node_expression_refs(node, catalog) do
      [] ->
        []

      refs ->
        [
          Issue.new(
            "#{node_path(indexes, id)}.params",
            :node_ref_unsupported_in_map_region,
            "step #{inspect(id)} is inside a map region and cannot reference $node values (got #{inspect(refs)})"
          )
        ]
    end
  end

  defp map_region_reference_issues(nodes, catalog, body_ids, indexes) do
    Enum.flat_map(nodes, fn node ->
      id = node["id"]

      if MapSet.member?(body_ids, id) do
        []
      else
        refs = Enum.filter(node_expression_refs(node, catalog), &MapSet.member?(body_ids, &1))

        case refs do
          [] ->
            []

          _refs ->
            [
              Issue.new(
                "#{node_path(indexes, id)}.params",
                :map_region_node_ref,
                "nodes outside a map region cannot reference per-item region nodes via $node (got #{inspect(refs)})"
              )
            ]
        end
      end
    end)
  end

  defp node_expression_refs(%{"type" => type, "version" => version} = node, catalog) do
    with {:ok, module} <- Catalog.fetch(catalog, type, version),
         spec <- module.__catalog_node__(),
         {:ok, params} <-
           Params.cast(
             Map.get(node, "params", %{}),
             spec.params_schema,
             spec.expr_fields,
             spec.predicate_fields
           ) do
      Expr.node_references(params)
    else
      _other -> []
    end
  end

  defp node_expression_refs(_node, _catalog), do: []

  defp node_kind(id, specs) do
    case Map.fetch(specs, id) do
      {:ok, spec} -> spec.kind
      :error -> nil
    end
  end

  defp node_path(indexes, id) do
    case Map.fetch(indexes, id) do
      {:ok, index} -> "$.nodes[#{index}]"
      :error -> "$.nodes"
    end
  end
end
