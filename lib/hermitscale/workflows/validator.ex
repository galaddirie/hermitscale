defmodule Hermitscale.Workflows.Validator do
  @moduledoc """
  Validates stored workflow graph JSON before it is compiled into Runic structs.
  """

  alias Hermitscale.Workflows.{Catalog, Expr, Policy}
  alias Hermitscale.Workflows.Nodes.Params

  defmodule Issue do
    @moduledoc """
    Structured validation issue returned to editors and forms.
    """

    @enforce_keys [:path, :code, :message]
    defstruct [:path, :code, :message, severity: :error]
  end

  @node_id_pattern ~r/^[A-Za-z][A-Za-z0-9_:-]*$/
  @max_nodes 100

  @doc """
  Validates a graph and returns all issues at once.
  """
  def validate(graph) do
    issues = issues(graph)

    case Enum.reject(issues, &(&1.severity == :warning)) do
      [] -> :ok
      _errors -> {:error, issues}
    end
  end

  @doc """
  Returns all validation issues, including warnings.
  """
  def issues(graph) do
    base_issues = graph_shape_issues(graph)

    if base_issues == [] do
      catalog = Catalog.index()
      nodes = node_specs(graph)
      connections = graph["connections"] || []
      nodes_by_id = Map.new(nodes, &{&1["id"], &1})

      base_issues ++
        duplicate_node_issues(nodes) ++
        node_issues(nodes, catalog, connections) ++
        expression_reference_issues(nodes, catalog, connections, nodes_by_id) ++
        connection_issues(connections, nodes_by_id) ++
        arity_issues(nodes, catalog, connections) ++
        policy_issues(nodes) ++
        cycle_issues(graph)
    else
      base_issues
    end
  end

  @doc """
  Topologically sorts node ids or returns validation issues.
  """
  def topo_order(graph) do
    nodes = node_specs(graph)
    connections = graph["connections"] || []
    ids = Enum.map(nodes, & &1["id"])
    parents = parent_map(connections)
    children = child_map(connections)
    incoming_counts = Map.new(ids, &{&1, length(Map.get(parents, &1, []))})

    queue =
      ids
      |> Enum.filter(&(Map.fetch!(incoming_counts, &1) == 0))
      |> :queue.from_list()

    sorted = do_topo(queue, incoming_counts, children, [])

    if length(sorted) == length(ids) do
      {:ok, sorted}
    else
      {:error, [issue("$.connections", :cycle, "workflow graph must be acyclic")]}
    end
  end

  def parent_map(connections) do
    connections
    |> Enum.group_by(& &1["to"])
    |> Map.new(fn {to, edges} ->
      ordered =
        edges
        |> Enum.sort_by(&Map.get(&1, "to_input", 0))
        |> Enum.map(& &1["from"])

      {to, ordered}
    end)
  end

  def node_specs(graph) when is_map(graph) do
    Map.get(graph, "nodes") || []
  end

  defp graph_shape_issues(graph) when is_map(graph) do
    []
    |> require_field(graph, "schema_version", "$.schema_version")
    |> require_field(graph, "id", "$.id")
    |> require_field(graph, "name", "$.name")
    |> require_field(graph, "nodes", "$.nodes")
    |> require_field(graph, "connections", "$.connections")
    |> validate_schema_version(graph)
    |> validate_nodes_shape(graph)
    |> validate_connections_shape(graph)
  end

  defp graph_shape_issues(_graph), do: [issue("$", :invalid_type, "graph must be a JSON object")]

  defp require_field(issues, graph, key, path) do
    if Map.has_key?(graph, key) do
      issues
    else
      [issue(path, :required, "#{key} is required") | issues]
    end
  end

  defp validate_schema_version(issues, %{"schema_version" => 1}), do: issues

  defp validate_schema_version(issues, %{"schema_version" => version}) do
    [
      issue(
        "$.schema_version",
        :unsupported_schema_version,
        "unsupported schema version #{inspect(version)}"
      )
      | issues
    ]
  end

  defp validate_schema_version(issues, _graph), do: issues

  defp validate_nodes_shape(issues, graph) do
    case fetch_nodes(graph) do
      {:ok, nodes} when is_list(nodes) ->
        validate_nodes_list(issues, nodes)

      {:ok, _nodes} ->
        [issue("$.nodes", :invalid_type, "nodes must be a list") | issues]

      :error ->
        issues
    end
  end

  defp fetch_nodes(%{"nodes" => nodes}), do: {:ok, nodes}
  defp fetch_nodes(_graph), do: :error

  defp validate_nodes_list(issues, nodes) do
    issues =
      if length(nodes) > @max_nodes do
        [
          issue(
            "$.nodes",
            :too_many_nodes,
            "workflow graphs are limited to #{@max_nodes} nodes"
          )
          | issues
        ]
      else
        issues
      end

    Enum.with_index(nodes)
    |> Enum.reduce(issues, fn
      {node, index}, acc when is_map(node) ->
        acc
        |> require_field(node, "id", "$.nodes[#{index}].id")
        |> require_field(node, "type", "$.nodes[#{index}].type")
        |> require_field(node, "version", "$.nodes[#{index}].version")

      {_node, index}, acc ->
        [issue("$.nodes[#{index}]", :invalid_type, "node must be an object") | acc]
    end)
  end

  defp validate_connections_shape(issues, %{"connections" => connections})
       when is_list(connections) do
    Enum.with_index(connections)
    |> Enum.reduce(issues, fn
      {connection, index}, acc when is_map(connection) ->
        acc
        |> require_field(connection, "from", "$.connections[#{index}].from")
        |> require_field(connection, "to", "$.connections[#{index}].to")

      {_connection, index}, acc ->
        [issue("$.connections[#{index}]", :invalid_type, "connection must be an object") | acc]
    end)
  end

  defp validate_connections_shape(issues, %{"connections" => _connections}) do
    [issue("$.connections", :invalid_type, "connections must be a list") | issues]
  end

  defp validate_connections_shape(issues, _graph), do: issues

  defp duplicate_node_issues(nodes) do
    nodes
    |> Enum.map(& &1["id"])
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {id, count} when count > 1 ->
        [
          issue(
            "$.nodes",
            :duplicate_node_id,
            "node id #{inspect(id)} is duplicated"
          )
        ]

      _other ->
        []
    end)
  end

  defp node_issues(nodes, catalog, connections) do
    Enum.with_index(nodes)
    |> Enum.flat_map(fn {node, index} ->
      []
      |> validate_node_id(node, index)
      |> validate_node_resolution(node, index, catalog)
      |> validate_node_params(node, index, catalog)
      |> validate_deprecation(node, index, catalog, connections)
    end)
  end

  defp validate_node_id(issues, %{"id" => id}, index) when is_binary(id) do
    if Regex.match?(@node_id_pattern, id) do
      issues
    else
      [
        issue(
          "$.nodes[#{index}].id",
          :invalid_node_id,
          "node id must start with a letter and contain only letters, digits, _, :, or -"
        )
        | issues
      ]
    end
  end

  defp validate_node_id(issues, %{"id" => _id}, index) do
    [issue("$.nodes[#{index}].id", :invalid_type, "node id must be a string") | issues]
  end

  defp validate_node_id(issues, _node, _index), do: issues

  defp validate_node_resolution(
         issues,
         %{"type" => type, "version" => version},
         index,
         catalog
       )
       when is_binary(type) and is_integer(version) do
    case Catalog.fetch(catalog, type, version) do
      {:ok, _module} ->
        issues

      {:error, :not_found} ->
        [
          issue(
            "$.nodes[#{index}]",
            :unknown_catalog_node,
            "catalog node #{type}@#{version} is not deployed"
          )
          | issues
        ]
    end
  end

  defp validate_node_resolution(issues, _node, _index, _catalog), do: issues

  defp validate_node_params(
         issues,
         %{"type" => type, "version" => version} = node,
         index,
         catalog
       ) do
    case Catalog.fetch(catalog, type, version) do
      {:ok, module} ->
        params = Map.get(node, "params", %{})
        spec = module.__catalog_node__()

        issues ++ params_issues(params, module, spec, "$.nodes[#{index}].params")

      {:error, :not_found} ->
        issues
    end
  end

  defp validate_deprecation(
         issues,
         %{"type" => type, "version" => version},
         index,
         catalog,
         _connections
       ) do
    case Catalog.fetch(catalog, type, version) do
      {:ok, module} ->
        spec = module.__catalog_node__()

        if spec.deprecated do
          [
            issue(
              "$.nodes[#{index}]",
              :deprecated_catalog_node,
              "catalog node #{type}@#{version} is deprecated",
              :warning
            )
            | issues
          ]
        else
          issues
        end

      {:error, :not_found} ->
        issues
    end
  end

  defp params_issues(params, module, spec, path) when is_map(params) do
    allowed = MapSet.new(spec.params_schema, fn {field, _opts} -> Atom.to_string(field) end)

    unknown_issues =
      params
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(allowed, &1))
      |> Enum.map(&issue("#{path}.#{&1}", :unknown_param, "unknown param #{inspect(&1)}"))

    case Params.cast(params, spec.params_schema, spec.expr_fields, spec.predicate_fields) do
      {:ok, normalized} ->
        unknown_issues ++ validate_node_params_callback(module, normalized, path)

      {:error, error} ->
        [issue(path, :invalid_params, Exception.message(error)) | unknown_issues]
    end
  end

  defp params_issues(_params, _module, _spec, path) do
    [issue(path, :invalid_type, "params must be an object")]
  end

  defp validate_node_params_callback(module, params, path) do
    if function_exported?(module, :validate_params, 1) do
      case module.validate_params(params) do
        :ok -> []
        {:error, message} when is_binary(message) -> [issue(path, :invalid_params, message)]
      end
    else
      []
    end
  end

  defp expression_reference_issues(nodes, catalog, connections, nodes_by_id) do
    ancestors = ancestor_map(nodes, connections)

    nodes
    |> Enum.with_index()
    |> Enum.flat_map(fn {node, index} ->
      expression_reference_issues(node, index, catalog, nodes_by_id, ancestors)
    end)
  end

  defp expression_reference_issues(
         %{"id" => id, "type" => type, "version" => version} = node,
         index,
         catalog,
         nodes_by_id,
         ancestors
       ) do
    with {:ok, module} <- Catalog.fetch(catalog, type, version),
         spec <- module.__catalog_node__(),
         {:ok, params} <-
           Params.cast(
             Map.get(node, "params", %{}),
             spec.params_schema,
             spec.expr_fields,
             spec.predicate_fields
           ) do
      refs = Expr.node_references(params)

      cond do
        spec.kind == :reduce and refs != [] ->
          [
            issue(
              "$.nodes[#{index}].params",
              :node_ref_unsupported_in_reduce,
              "reduce nodes cannot reference other nodes via $node[...] (got #{inspect(refs)})"
            )
          ]

        true ->
          Enum.flat_map(refs, &node_reference_issues(&1, id, index, nodes_by_id, ancestors))
      end
    else
      _other -> []
    end
  end

  defp expression_reference_issues(_node, _index, _catalog, _nodes_by_id, _ancestors), do: []

  defp node_reference_issues(ref, id, index, nodes_by_id, ancestors) do
    cond do
      not Map.has_key?(nodes_by_id, ref) ->
        [
          issue(
            "$.nodes[#{index}].params",
            :missing_expression_node,
            "expression references missing node #{inspect(ref)}"
          )
        ]

      not MapSet.member?(Map.get(ancestors, id, MapSet.new()), ref) ->
        [
          issue(
            "$.nodes[#{index}].params",
            :non_upstream_expression_node,
            "expression references node #{inspect(ref)} which is not upstream of #{inspect(id)}"
          )
        ]

      true ->
        []
    end
  end

  defp connection_issues(connections, nodes_by_id) do
    Enum.with_index(connections)
    |> Enum.flat_map(fn {connection, index} ->
      []
      |> validate_endpoint(connection, index, "from", nodes_by_id)
      |> validate_endpoint(connection, index, "to", nodes_by_id)
      |> validate_to_input(connection, index)
    end)
  end

  defp validate_endpoint(issues, connection, index, field, nodes_by_id) do
    case Map.fetch(connection, field) do
      {:ok, id} when is_binary(id) ->
        if Map.has_key?(nodes_by_id, id) do
          issues
        else
          [
            issue(
              "$.connections[#{index}].#{field}",
              :missing_node,
              "connection references missing node #{inspect(id)}"
            )
            | issues
          ]
        end

      {:ok, _id} ->
        [
          issue("$.connections[#{index}].#{field}", :invalid_type, "#{field} must be a string")
          | issues
        ]

      :error ->
        issues
    end
  end

  defp validate_to_input(issues, %{"to_input" => value}, _index)
       when is_integer(value) and value >= 0 do
    issues
  end

  defp validate_to_input(issues, %{"to_input" => _value}, index) do
    [
      issue(
        "$.connections[#{index}].to_input",
        :invalid_type,
        "to_input must be a non-negative integer"
      )
      | issues
    ]
  end

  defp validate_to_input(issues, _connection, _index), do: issues

  defp arity_issues(nodes, catalog, connections) do
    incoming = Enum.group_by(connections, & &1["to"])

    Enum.with_index(nodes)
    |> Enum.flat_map(fn {node, index} ->
      with {:ok, module} <- Catalog.fetch(catalog, node["type"], node["version"]),
           %{kind: :join, inputs: inputs} <- module.__catalog_node__() do
        edges = Map.get(incoming, node["id"], [])
        slots = Enum.map(edges, &Map.get(&1, "to_input", 0))
        expected_slots = Enum.to_list(0..(length(inputs) - 1)//1)

        []
        |> validate_join_count(index, length(edges), length(inputs))
        |> validate_join_slots(index, slots, expected_slots)
      else
        _other -> []
      end
    end)
  end

  defp validate_join_count(issues, _index, count, count), do: issues

  defp validate_join_count(issues, index, count, expected) do
    [
      issue(
        "$.nodes[#{index}]",
        :join_arity,
        "join expects #{expected} inputs but has #{count} incoming connections"
      )
      | issues
    ]
  end

  defp validate_join_slots(issues, _index, slots, expected_slots) when slots == expected_slots do
    issues
  end

  defp validate_join_slots(issues, index, slots, expected_slots) do
    [
      issue(
        "$.nodes[#{index}]",
        :join_input_slots,
        "join input slots must be contiguous and unique: expected #{inspect(expected_slots)}, got #{inspect(slots)}"
      )
      | issues
    ]
  end

  defp policy_issues(nodes) do
    Enum.with_index(nodes)
    |> Enum.flat_map(fn
      {%{"policy" => policy}, index} when is_map(policy) ->
        validate_policy(policy, index)

      {%{"policy" => nil}, _index} ->
        []

      {%{"policy" => _policy}, index} ->
        [issue("$.nodes[#{index}].policy", :invalid_type, "policy must be an object")]

      {_node, _index} ->
        []
    end)
  end

  defp validate_policy(policy, index) do
    known_keys = MapSet.new(Policy.known_keys())

    unknown =
      policy
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(known_keys, &1))
      |> Enum.map(
        &issue(
          "$.nodes[#{index}].policy.#{&1}",
          :unknown_policy,
          "unknown policy key #{inspect(&1)}"
        )
      )

    enum_issues =
      Enum.flat_map(Policy.enum_values(), fn {key, values} ->
        case Map.fetch(policy, key) do
          {:ok, value} ->
            if value in values do
              []
            else
              [
                issue(
                  "$.nodes[#{index}].policy.#{key}",
                  :invalid_policy,
                  "#{key} must be one of #{Enum.join(values, ", ")}, got #{inspect(value)}"
                )
              ]
            end

          :error ->
            []
        end
      end)

    integer_issues =
      Enum.flat_map(Policy.integer_keys(), fn key ->
        case Map.fetch(policy, key) do
          {:ok, value} when is_integer(value) and value >= 0 ->
            []

          {:ok, value} ->
            [
              issue(
                "$.nodes[#{index}].policy.#{key}",
                :invalid_policy,
                "#{key} must be a non-negative integer, got #{inspect(value)}"
              )
            ]

          :error ->
            []
        end
      end)

    unknown ++ enum_issues ++ integer_issues
  end

  defp cycle_issues(graph) do
    case topo_order(graph) do
      {:ok, _order} -> []
      {:error, issues} -> issues
    end
  end

  defp child_map(connections) do
    connections
    |> Enum.group_by(& &1["from"])
    |> Map.new(fn {from, edges} -> {from, Enum.map(edges, & &1["to"])} end)
  end

  defp ancestor_map(nodes, connections) do
    parents = parent_map(connections)

    nodes
    |> Enum.map(& &1["id"])
    |> Map.new(fn id -> {id, collect_ancestors(id, parents, MapSet.new())} end)
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

  defp do_topo(queue, incoming_counts, children, sorted) do
    case :queue.out(queue) do
      {{:value, id}, queue} ->
        {queue, incoming_counts} =
          children
          |> Map.get(id, [])
          |> Enum.reduce({queue, incoming_counts}, fn child, {queue, incoming_counts} ->
            case Map.fetch(incoming_counts, child) do
              {:ok, current_count} ->
                count = current_count - 1
                incoming_counts = Map.put(incoming_counts, child, count)
                queue = if count == 0, do: :queue.in(child, queue), else: queue
                {queue, incoming_counts}

              :error ->
                {queue, incoming_counts}
            end
          end)

        do_topo(queue, incoming_counts, children, [id | sorted])

      {:empty, _queue} ->
        Enum.reverse(sorted)
    end
  end

  defp issue(path, code, message, severity \\ :error) do
    %Issue{path: path, code: code, message: message, severity: severity}
  end
end
