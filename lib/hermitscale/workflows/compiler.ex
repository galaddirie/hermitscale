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

    modules =
      Map.new(nodes, fn {id, node} ->
        {id, Catalog.fetch!(catalog, node["type"], node["version"])}
      end)

    specs = Map.new(modules, fn {id, module} -> {id, module.__catalog_node__()} end)
    main_parents = Validator.parent_map(graph["connections"] || [])
    children = child_map(graph["connections"] || [])

    # Reduce reducers run under Runic's fan-in coordinator, which calls them as
    # `reducer/2` (no `context/1`). The ambient namespaces come from the graph
    # at compile time, so we bake them into the reduce closure instead.
    compile_context = %{
      ambient: expr_runtime(graph),
      children: children,
      main_parents: main_parents,
      modules: modules,
      nodes: nodes,
      specs: specs
    }

    initial_state = %{consumed: MapSet.new(), outputs: %{}, workflow: base_workflow(graph)}

    order
    |> Enum.reduce(initial_state, &compile_node(&1, &2, compile_context))
    |> Map.fetch!(:workflow)
  end

  defp compile_node(id, state, compile_context) do
    cond do
      MapSet.member?(state.consumed, id) ->
        state

      kind_for(id, compile_context) == :map ->
        compile_map_region(id, state, compile_context)

      true ->
        compile_outer_node(id, state, compile_context)
    end
  end

  defp compile_outer_node(id, state, compile_context) do
    case kind_for(id, compile_context) do
      :reduce ->
        raise ArgumentError, "reduce node #{inspect(id)} must be compiled as part of a map region"

      _other ->
        {node, parents} = build_outer_node(id, compile_context)
        parent_refs = output_refs(parents, state.outputs)

        workflow =
          state.workflow
          |> add_node(node, parent_refs)
          |> add_node_policy(id, compile_context)

        %{state | outputs: Map.put(state.outputs, id, id), workflow: workflow}
    end
  end

  # Wires a map region as first-class Runic nodes: prepare -> fan_out -> mapper,
  # then the per-item body chain, then (if present) the reduce's fan-in bound
  # structurally to the fan-out. Body steps run per element via ordinary edges.
  defp compile_map_region(map_id, state, compile_context) do
    region = map_region(map_id, compile_context)
    {prepare, fan_out, mapper, parents} = build_map_node(map_id, compile_context)
    parent_refs = output_refs(parents, state.outputs)

    workflow =
      state.workflow
      |> add_node(prepare, parent_refs)
      |> Workflow.attach_fan_out(fan_out, to: prepare)
      |> Workflow.add_step(fan_out, mapper)
      |> Workflow.register_component(mapper)
      |> add_node_policy(map_id, compile_context)

    {workflow, leaf} =
      Enum.reduce(region.body_ids, {workflow, mapper}, fn body_id, {workflow, previous} ->
        step = build_region_step(body_id, previous.name, compile_context)

        workflow =
          workflow
          |> Workflow.add_step(previous, step)
          |> add_node_policy(body_id, compile_context)

        {workflow, step}
      end)

    state =
      %{state | outputs: Map.put(state.outputs, map_id, mapper.name), workflow: workflow}
      |> consume_nodes(region.body_ids)

    case region.reduce_id do
      nil ->
        state

      reduce_id ->
        fan_in = build_reduce_node(reduce_id, compile_context)

        workflow =
          state.workflow
          |> Workflow.attach_fan_in(fan_in, fan_out, from: leaf)
          |> add_node_policy(reduce_id, compile_context)

        %{
          state
          | consumed: MapSet.put(state.consumed, reduce_id),
            outputs: Map.put(state.outputs, reduce_id, fan_in.name),
            workflow: workflow
        }
    end
  end

  defp build_outer_node(id, compile_context) do
    mains = Map.get(compile_context.main_parents, id, [])
    params = node_params(id, compile_context)

    # `$node["X"]` references become explicit edges. Refs are validated to be
    # upstream ancestors, so they are already earlier in the topo order; we
    # only add the edge and let the node rebuild its `$node` view from inputs.
    refs = Expr.node_references(params) -- mains
    parents = mains ++ refs

    build_context = %{
      ambient: compile_context.ambient,
      main_count: length(mains),
      name: id,
      parents: parents,
      ref_ids: refs
    }

    {build_node(id, params, build_context, compile_context), parents}
  end

  defp build_map_node(id, compile_context) do
    mains = Map.get(compile_context.main_parents, id, [])
    params = node_params(id, compile_context)
    refs = Expr.node_references(params) -- mains
    parents = mains ++ refs

    {:region, prepare, fan_out, mapper} =
      build_node(id, params, %{name: id, ref_ids: refs}, compile_context)

    {prepare, fan_out, mapper, parents}
  end

  defp build_reduce_node(id, compile_context) do
    params = node_params(id, compile_context)
    build_node(id, params, %{ambient: compile_context.ambient, name: id}, compile_context)
  end

  defp build_region_step(id, previous_id, compile_context) do
    params = node_params(id, compile_context)

    build_node(
      id,
      params,
      %{main_count: 1, name: id, parents: [previous_id]},
      compile_context
    )
  end

  defp build_node(id, params, build_context, compile_context) do
    compile_context.modules
    |> Map.fetch!(id)
    |> apply(:build, [params, build_context])
  end

  defp map_region(map_id, compile_context) do
    case Map.get(compile_context.children, map_id, []) do
      [] -> %{body_ids: [], reduce_id: nil}
      [child] -> collect_map_region(child, compile_context, [])
    end
  end

  defp collect_map_region(id, compile_context, body_ids) do
    case kind_for(id, compile_context) do
      :reduce ->
        %{body_ids: Enum.reverse(body_ids), reduce_id: id}

      :step ->
        case Map.get(compile_context.children, id, []) do
          [] -> %{body_ids: Enum.reverse([id | body_ids]), reduce_id: nil}
          [child] -> collect_map_region(child, compile_context, [id | body_ids])
        end
    end
  end

  defp node_params(id, compile_context) do
    node = Map.fetch!(compile_context.nodes, id)
    spec = Map.fetch!(compile_context.specs, id)

    Params.cast!(
      node["params"] || %{},
      spec.params_schema,
      spec.expr_fields,
      spec.predicate_fields
    )
  end

  defp output_refs(parents, outputs) do
    Enum.map(parents, &Map.fetch!(outputs, &1))
  end

  defp consume_nodes(state, ids) do
    %{state | consumed: Enum.reduce(ids, state.consumed, &MapSet.put(&2, &1))}
  end

  defp kind_for(id, compile_context), do: Map.fetch!(compile_context.specs, id).kind

  defp child_map(connections) do
    connections
    |> Enum.group_by(& &1["from"])
    |> Map.new(fn {from, edges} -> {from, Enum.map(edges, & &1["to"])} end)
  end

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

  defp add_node(workflow, node, []), do: Workflow.add(workflow, node, log: false)

  defp add_node(workflow, node, [parent]),
    do: Workflow.add(workflow, node, to: parent, log: false)

  defp add_node(workflow, node, parents),
    do: Workflow.add(workflow, node, to: parents, log: false)

  defp add_node_policy(workflow, id, compile_context) do
    node_spec = Map.fetch!(compile_context.nodes, id)
    spec = Map.fetch!(compile_context.specs, id)

    add_policy(workflow, node_spec, spec)
  end

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
