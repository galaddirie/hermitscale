defmodule Hermitscale.Workflows.CollectionScopes do
  @moduledoc """
  Assigns collection scopes to an acyclic workflow graph.

  Maps open a scope and reductions or aggregations close the innermost scope.
  Branches may converge through an explicit join when their scopes match.
  """

  alias Hermitscale.Workflows.{Catalog, Topology}
  alias Hermitscale.Workflows.Validator.Issue

  @type scope :: %{
          input: [String.t()],
          output: [String.t()],
          map: String.t() | nil
        }

  @doc "Returns each node's incoming and outgoing collection scope."
  @spec analyze(map(), %{String.t() => atom()}) ::
          {:ok, %{String.t() => scope()}} | {:error, [Issue.t()]}
  def analyze(%{"nodes" => nodes, "connections" => connections} = graph, kinds) do
    parents = Topology.parent_map(connections)
    indexes = nodes |> Enum.with_index() |> Map.new(fn {node, index} -> {node["id"], index} end)

    case Topology.order(graph) do
      {:ok, order} ->
        {scopes, issues} =
          Enum.reduce(order, {%{}, []}, fn id, {scopes, issues} ->
            kind = Map.get(kinds, id, :step)
            parent_ids = Map.get(parents, id, [])
            parent_scopes = Enum.map(parent_ids, &Map.fetch!(scopes, &1).output)
            path = "$.nodes[#{Map.fetch!(indexes, id)}]"

            {input_scope, scope_issues} = input_scope(parent_scopes, path, id)
            arity_issues = parent_issues(kind, parent_ids, path, id)
            {scope, owner_issues} = node_scope(kind, input_scope, path, id)

            {Map.put(scopes, id, scope), issues ++ scope_issues ++ arity_issues ++ owner_issues}
          end)

        case issues do
          [] -> {:ok, scopes}
          issues -> {:error, issues}
        end

      {:error, :cycle} ->
        {:error, [Issue.new("$.connections", :cycle, "workflow graph must be acyclic")]}
    end
  end

  def issues(nodes, catalog, connections) do
    kinds =
      Enum.reduce(nodes, %{}, fn
        %{"id" => id, "type" => type, "version" => version}, kinds
        when is_binary(id) and is_binary(type) and is_integer(version) ->
          case Catalog.fetch(catalog, type, version) do
            {:ok, module} -> Map.put(kinds, id, module.__catalog_node__().kind)
            {:error, :not_found} -> kinds
          end

        _node, kinds ->
          kinds
      end)

    case analyze(%{"nodes" => nodes, "connections" => connections}, kinds) do
      {:ok, _scopes} -> []
      {:error, issues} -> issues
    end
  end

  defp input_scope(parent_scopes, path, id) do
    case Enum.uniq(parent_scopes) do
      [] ->
        {[], []}

      [scope] ->
        {scope, []}

      scopes ->
        {[],
         [
           Issue.new(
             path,
             :mixed_collection_scopes,
             "node #{inspect(id)} receives different collection scopes #{inspect(scopes)}; aggregate each inner collection before joining"
           )
         ]}
    end
  end

  defp parent_issues(kind, [_parent], _path, _id) when kind in [:reduce, :aggregate], do: []

  defp parent_issues(kind, parents, path, id) when kind in [:reduce, :aggregate] do
    [
      Issue.new(
        path,
        :reduce_parent_count,
        "#{kind} node #{inspect(id)} must have exactly one structural parent, got #{length(parents)}"
      )
    ]
  end

  defp parent_issues(:join, _parents, _path, _id), do: []
  defp parent_issues(_kind, parents, _path, _id) when length(parents) <= 1, do: []

  defp parent_issues(_kind, parents, path, id) do
    [
      Issue.new(
        path,
        :implicit_join,
        "node #{inspect(id)} has #{length(parents)} structural parents; use an explicit join to converge branches"
      )
    ]
  end

  defp node_scope(:map, input, _path, id),
    do: {%{input: input, output: input ++ [id], map: List.last(input)}, []}

  defp node_scope(kind, [], path, id) when kind in [:reduce, :aggregate] do
    {%{input: [], output: [], map: nil},
     [
       Issue.new(
         path,
         :reduce_without_map,
         "#{kind} node #{inspect(id)} must close an upstream map collection"
       )
     ]}
  end

  defp node_scope(kind, input, _path, _id) when kind in [:reduce, :aggregate],
    do: {%{input: input, output: Enum.drop(input, -1), map: List.last(input)}, []}

  defp node_scope(_kind, input, _path, _id),
    do: {%{input: input, output: input, map: List.last(input)}, []}
end
