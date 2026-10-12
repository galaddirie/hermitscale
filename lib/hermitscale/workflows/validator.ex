defmodule Hermitscale.Workflows.Validator do
  @moduledoc """
  Validates stored workflow graph JSON before it is compiled into Runic structs.
  """

  alias Hermitscale.Workflows.{Catalog, CollectionScopes, Expr, Policy, Topology}
  alias Hermitscale.Workflows.Nodes.Params

  alias Hermitscale.Workflows.Validator.Issue

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
      connections = Map.fetch!(graph, "connections")
      nodes_by_id = Map.new(nodes, &{&1["id"], &1})
      connection_issues = connection_issues(connections, nodes_by_id)
      cycle_issues = if connection_issues == [], do: cycle_issues(graph), else: []

      region_issues =
        case {connection_issues, cycle_issues} do
          {[], []} -> CollectionScopes.issues(nodes, catalog, connections)
          _issues -> []
        end

      base_issues ++
        duplicate_node_issues(nodes) ++
        trigger_issues(nodes, catalog, connections) ++
        node_issues(nodes, catalog, connections) ++
        credential_issues(graph, nodes) ++
        expression_reference_issues(nodes, catalog, connections, nodes_by_id) ++
        connection_issues ++
        region_issues ++
        arity_issues(nodes, catalog, connections) ++
        policy_issues(nodes) ++
        cycle_issues
    else
      base_issues
    end
  end

  @doc """
  Topologically sorts node ids or returns validation issues.
  """
  def topo_order(graph) do
    with [] <- graph_shape_issues(graph),
         nodes_by_id = Map.new(node_specs(graph), &{&1["id"], &1}),
         [] <- connection_issues(Map.fetch!(graph, "connections"), nodes_by_id) do
      case Topology.order(graph) do
        {:ok, sorted} ->
          {:ok, sorted}

        {:error, :cycle} ->
          {:error, [Issue.new("$.connections", :cycle, "workflow graph must be acyclic")]}
      end
    else
      issues when is_list(issues) -> {:error, issues}
    end
  end

  defdelegate parent_map(connections), to: Topology

  def node_specs(graph) when is_map(graph) do
    Map.get(graph, "nodes") || []
  end

  defp credential_issues(graph, nodes) do
    graph_issues =
      case Map.has_key?(graph, "credentials") do
        true -> [Issue.new("$.credentials", :legacy_credentials, "use node connection objects")]
        false -> []
      end

    Enum.with_index(nodes)
    |> Enum.reduce(graph_issues, fn {node, index}, acc ->
      path = "$.nodes[#{index}]"

      legacy =
        case Map.has_key?(node, "credentials") do
          true ->
            [Issue.new(path <> ".credentials", :legacy_credentials, "use a connection object")]

          false ->
            []
        end

      selection =
        case node["connection"] do
          nil ->
            []

          connection ->
            requirement = Hermitscale.Workflows.Credentials.requirement(node)

            result =
              case requirement do
                nil ->
                  {:error, :unexpected_connection}

                requirement ->
                  Hermitscale.Integrations.ConnectedAccounts.validate_selection(
                    connection,
                    Keyword.get(requirement, :provider)
                  )
              end

            case result do
              :ok ->
                []

              {:error, _reason} ->
                [
                  Issue.new(
                    path <> ".connection",
                    :invalid_connection,
                    "select an account from the node's deployed integration"
                  )
                ]
            end
        end

      acc ++ legacy ++ selection
    end)
  end

  defp graph_shape_issues(graph) when is_map(graph) do
    []
    |> require_field(graph, "schema_version", "$.schema_version")
    |> require_field(graph, "id", "$.id")
    |> require_field(graph, "name", "$.name")
    |> require_field(graph, "nodes", "$.nodes")
    |> require_field(graph, "connections", "$.connections")
    |> validate_schema_version(graph)
    |> validate_string_field(graph, "id", "$.id")
    |> validate_string_field(graph, "name", "$.name")
    |> validate_object_field(graph, "env", "$.env")
    |> validate_object_field(graph, "vars", "$.vars")
    |> validate_nodes_shape(graph)
    |> validate_connections_shape(graph)
  end

  defp graph_shape_issues(_graph),
    do: [Issue.new("$", :invalid_type, "graph must be a JSON object")]

  defp require_field(issues, graph, key, path) do
    if Map.has_key?(graph, key) do
      issues
    else
      [Issue.new(path, :required, "#{key} is required") | issues]
    end
  end

  defp validate_schema_version(issues, %{"schema_version" => 1}), do: issues

  defp validate_schema_version(issues, %{"schema_version" => version}) do
    [
      Issue.new(
        "$.schema_version",
        :unsupported_schema_version,
        "unsupported schema version #{inspect(version)}"
      )
      | issues
    ]
  end

  defp validate_schema_version(issues, _graph), do: issues

  defp validate_string_field(issues, data, key, path) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 ->
        issues

      {:ok, _value} ->
        [Issue.new(path, :invalid_type, "#{key} must be a non-empty string") | issues]

      :error ->
        issues
    end
  end

  defp validate_object_field(issues, data, key, path) do
    case Map.fetch(data, key) do
      {:ok, value} when is_map(value) -> issues
      {:ok, _value} -> [Issue.new(path, :invalid_type, "#{key} must be an object") | issues]
      :error -> issues
    end
  end

  defp validate_node_version(issues, node, index) do
    case Map.fetch(node, "version") do
      {:ok, version} when is_integer(version) and version > 0 ->
        issues

      {:ok, _version} ->
        [
          Issue.new(
            "$.nodes[#{index}].version",
            :invalid_type,
            "version must be a positive integer"
          )
          | issues
        ]

      :error ->
        issues
    end
  end

  defp validate_nodes_shape(issues, graph) do
    case fetch_nodes(graph) do
      {:ok, nodes} when is_list(nodes) ->
        validate_nodes_list(issues, nodes)

      {:ok, _nodes} ->
        [Issue.new("$.nodes", :invalid_type, "nodes must be a list") | issues]

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
          Issue.new(
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
        |> validate_string_field(node, "type", "$.nodes[#{index}].type")
        |> validate_node_version(node, index)
        |> validate_object_field(node, "params", "$.nodes[#{index}].params")

      {_node, index}, acc ->
        [Issue.new("$.nodes[#{index}]", :invalid_type, "node must be an object") | acc]
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
        [
          Issue.new("$.connections[#{index}]", :invalid_type, "connection must be an object")
          | acc
        ]
    end)
  end

  defp validate_connections_shape(issues, %{"connections" => _connections}) do
    [Issue.new("$.connections", :invalid_type, "connections must be a list") | issues]
  end

  defp validate_connections_shape(issues, _graph), do: issues

  defp duplicate_node_issues(nodes) do
    nodes
    |> Enum.map(& &1["id"])
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {id, count} when count > 1 ->
        [
          Issue.new(
            "$.nodes",
            :duplicate_node_id,
            "node id #{inspect(id)} is duplicated"
          )
        ]

      _other ->
        []
    end)
  end

  # Triggers are workflow entry points: they receive the firing payload from
  # the dispatcher, never from another node.
  defp trigger_issues(nodes, catalog, connections) do
    inbound = MapSet.new(connections, & &1["to"])

    Enum.with_index(nodes)
    |> Enum.flat_map(fn {node, index} ->
      with %{"id" => id, "type" => type, "version" => version} <- node,
           {:ok, module} <- Catalog.fetch(catalog, type, version),
           %{kind: :trigger} <- module.__catalog_node__(),
           true <- MapSet.member?(inbound, id) do
        [
          Issue.new(
            "$.nodes[#{index}]",
            :trigger_with_inputs,
            "trigger node #{inspect(id)} cannot have incoming connections"
          )
        ]
      else
        _other -> []
      end
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
        Issue.new(
          "$.nodes[#{index}].id",
          :invalid_node_id,
          "node id must start with a letter and contain only letters, digits, _, :, or -"
        )
        | issues
      ]
    end
  end

  defp validate_node_id(issues, %{"id" => _id}, index) do
    [Issue.new("$.nodes[#{index}].id", :invalid_type, "node id must be a string") | issues]
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
          Issue.new(
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
            Issue.new(
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
      |> Enum.map(&Issue.new("#{path}.#{&1}", :unknown_param, "unknown param #{inspect(&1)}"))

    case Params.cast(params, spec.params_schema, spec.expr_fields, spec.predicate_fields) do
      {:ok, normalized} ->
        unknown_issues ++ validate_node_params_callback(module, normalized, path)

      {:error, error} ->
        [Issue.new(path, :invalid_params, Exception.message(error)) | unknown_issues]
    end
  end

  defp params_issues(_params, _module, _spec, path) do
    [Issue.new(path, :invalid_type, "params must be an object")]
  end

  defp validate_node_params_callback(module, params, path) do
    if function_exported?(module, :validate_params, 1) do
      case module.validate_params(params) do
        :ok -> []
        {:error, message} when is_binary(message) -> [Issue.new(path, :invalid_params, message)]
      end
    else
      []
    end
  end

  defp expression_reference_issues(nodes, catalog, connections, nodes_by_id) do
    ancestors = Topology.ancestor_map(nodes, connections)

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

      Enum.flat_map(refs, &node_reference_issues(&1, id, index, nodes_by_id, ancestors))
    else
      _other -> []
    end
  end

  defp expression_reference_issues(_node, _index, _catalog, _nodes_by_id, _ancestors), do: []

  defp node_reference_issues(ref, id, index, nodes_by_id, ancestors) do
    cond do
      not Map.has_key?(nodes_by_id, ref) ->
        [
          Issue.new(
            "$.nodes[#{index}].params",
            :missing_expression_node,
            "expression references missing node #{inspect(ref)}"
          )
        ]

      not MapSet.member?(Map.get(ancestors, id, MapSet.new()), ref) ->
        [
          Issue.new(
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
            Issue.new(
              "$.connections[#{index}].#{field}",
              :missing_node,
              "connection references missing node #{inspect(id)}"
            )
            | issues
          ]
        end

      {:ok, _id} ->
        [
          Issue.new(
            "$.connections[#{index}].#{field}",
            :invalid_type,
            "#{field} must be a string"
          )
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
      Issue.new(
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
        slots = edges |> Enum.map(&Map.get(&1, "to_input", 0)) |> Enum.sort()
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
      Issue.new(
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
      Issue.new(
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

      {%{"policy" => _policy}, index} ->
        [Issue.new("$.nodes[#{index}].policy", :invalid_type, "policy must be an object")]

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
        &Issue.new(
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
                Issue.new(
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
              Issue.new(
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
end
