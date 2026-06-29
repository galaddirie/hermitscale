defmodule Hermitscale.Workflows.Compiler do
  @moduledoc """
  Compiles validated workflow graph JSON into `Runic.Workflow` structs.
  """

  require Runic

  alias Hermitscale.Workflows.{Catalog, Expr, Policy, Validator}
  alias Hermitscale.Workflows.Nodes.Params
  alias Runic.Workflow

  @doc """
  Compiles a graph into a Runic workflow.
  """
  def compile(graph) do
    with :ok <- Validator.validate(graph),
         {:ok, order} <- Validator.topo_order(graph) do
      {:ok, do_compile(graph, order)}
    end
  end

  @doc """
  Compiles a graph or raises on validation errors.
  """
  def compile!(graph) do
    case compile(graph) do
      {:ok, workflow} -> workflow
      {:error, issues} -> raise ArgumentError, "invalid workflow graph: #{inspect(issues)}"
    end
  end

  defp do_compile(graph, order) do
    catalog = Catalog.index()
    node_specs = Validator.node_specs(graph)
    nodes = Map.new(node_specs, &{&1["id"], &1})
    main_parents = Validator.parent_map(graph["connections"] || [])
    # Reduce reducers run under Runic's fan-in coordinator, which calls them as
    # `reducer/2` (no `context/1`). The ambient namespaces come from the graph
    # at compile time, so we bake them into the reduce closure instead.
    ambient = expr_runtime(graph)

    Enum.reduce(order, base_workflow(graph), fn id, workflow ->
      node_spec = Map.fetch!(nodes, id)
      module = Catalog.fetch!(catalog, node_spec["type"], node_spec["version"])
      spec = module.__catalog_node__()
      mains = Map.get(main_parents, id, [])

      params =
        Params.cast!(
          node_spec["params"] || %{},
          spec.params_schema,
          spec.expr_fields,
          spec.predicate_fields
        )

      # `$node["X"]` references become explicit edges. Refs are validated to be
      # upstream ancestors, so they are already earlier in the topo order; we
      # only add the edge and let the node rebuild its `$node` view from inputs.
      refs = Expr.node_references(params) -- mains
      parents = mains ++ refs

      ctx = %{
        name: id,
        main_count: length(mains),
        parents: parents,
        ref_ids: refs,
        map_name: map_name(mains, nodes, catalog),
        ambient: ambient
      }

      node = module.build(params, ctx)

      workflow
      |> add_built(spec.kind, node, mains, parents)
      |> add_policy(node_spec, spec)
    end)
  end

  # A map is a spread step + a Runic.map; wire the spread to the node's parents
  # (collection + any reference edges) and the map to the spread.
  defp add_built(workflow, :map, {:pipeline, spread, mapper}, _mains, parents) do
    workflow
    |> add_node(spread, parents)
    |> Workflow.add(mapper, to: spread.name)
  end

  # A reduce fans in from its upstream map (lazy) or a list-producing step.
  defp add_built(workflow, :reduce, reduce, mains, _parents) do
    add_node(workflow, reduce, mains)
  end

  defp add_built(workflow, _kind, node, _mains, parents) do
    add_node(workflow, node, parents)
  end

  # The upstream map name enables Runic's lazy fan-in; nil for an enumerable
  # reduce that follows a plain list-producing step.
  defp map_name([parent], nodes, catalog) do
    with %{} = parent_spec <- Map.get(nodes, parent),
         {:ok, module} <- Catalog.fetch(catalog, parent_spec["type"], parent_spec["version"]),
         %{kind: :map} <- module.__catalog_node__() do
      parent
    else
      _other -> nil
    end
  end

  defp map_name(_mains, _nodes, _catalog), do: nil

  defp base_workflow(graph) do
    graph
    |> expr_run_context()
    |> then(&(Runic.workflow(name: graph["name"]) |> Workflow.put_run_context(&1)))
  end

  defp expr_run_context(graph) do
    %{_global: %{_expr: expr_runtime(graph)}}
  end

  defp expr_runtime(graph) do
    %{
      env: Map.get(graph, "env", %{}),
      execution: %{},
      vars: Map.get(graph, "vars", %{}),
      workflow: %{
        "id" => graph["id"],
        "name" => graph["name"]
      }
    }
  end

  defp add_node(workflow, node, []), do: Workflow.add(workflow, node)

  defp add_node(workflow, node, [parent]),
    do: Workflow.add(workflow, node, to: parent)

  defp add_node(workflow, node, parents),
    do: Workflow.add(workflow, node, to: parents)

  defp add_policy(workflow, %{"id" => id} = node_spec, spec) do
    default_policy = spec.default_policy
    node_policy = Map.get(node_spec, "policy", %{})

    policy = Map.merge(default_policy, Policy.normalize(node_policy))

    if map_size(policy) == 0 do
      workflow
    else
      Workflow.add_scheduler_policy(workflow, {:name, exact_name(id)}, policy)
    end
  end

  defp exact_name(id), do: Regex.compile!("\\A#{Regex.escape(id)}\\z")
end
