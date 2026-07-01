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

  defp compile_map_region(map_id, state, compile_context) do
    region = map_region(map_id, compile_context)
    {spread, mapper, parents} = build_map_node(map_id, compile_context)
    parent_refs = output_refs(parents, state.outputs)
    mapper = append_map_pipeline(mapper, region.body_ids, compile_context)

    workflow =
      state.workflow
      |> add_node(spread, parent_refs)
      |> Workflow.add(mapper, to: spread.name, log: false)
      |> add_node_policy(map_id, compile_context)
      |> add_node_policies(region.body_ids, compile_context)

    state =
      %{state | outputs: Map.put(state.outputs, map_id, map_id), workflow: workflow}
      |> consume_nodes(region.body_ids)

    case region.reduce_id do
      nil ->
        state

      reduce_id ->
        reduce = build_reduce_node(reduce_id, map_id, compile_context)

        workflow =
          state.workflow
          |> Workflow.add(reduce, to: map_id, log: false)
          |> add_node_policy(reduce_id, compile_context)

        %{
          state
          | consumed: MapSet.put(state.consumed, reduce_id),
            outputs: Map.put(state.outputs, reduce_id, reduce_output(workflow, reduce_id)),
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

    {:pipeline, spread, mapper} =
      build_node(id, params, %{name: id, ref_ids: refs}, compile_context)

    {spread, mapper, parents}
  end

  defp build_reduce_node(id, map_id, compile_context) do
    params = node_params(id, compile_context)

    build_node(
      id,
      params,
      %{ambient: compile_context.ambient, map_name: map_id, name: id},
      compile_context
    )
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

  # Splices the map region's body steps into the mapper's internal pipeline so
  # they run once per fanned-out element, between the map and its reduce.
  #
  # WHY WE REACH INTO `mapper.pipeline` (a Runic internal):
  #
  # Runic only exposes a multi-step map body through the compile-time
  # `Runic.map({step, [steps]})` macro, which pattern-matches step *AST* during
  # macro expansion (see `Runic.map/2` and `pipeline_workflow_of_map_expression/3`
  # in runic.ex). Our steps are built at runtime from cast params, so that macro
  # form is unavailable to us — there is no public *runtime* builder for adding a
  # step to a map's per-element pipeline.
  #
  # The obvious public-API alternatives do NOT work — both silently bypass the
  # body step. We verified empirically with `map(×2) → step(+1) → reduce(sum)`
  # over [1,2,3] (expected 15):
  #
  #   * step + reduce added to the main graph, reduce attached to the step:
  #     the step is skipped and the reduce never fires.
  #   * step + reduce both attached to the map in the main graph:
  #     the reduce folds the raw map output (12), bypassing the step.
  #
  # The reason: a reduce's fan-in attaches to the map's pipeline `:leaf`
  # (`Runic.Component.connect/3`, the `{map.name, :leaf}` lookup), and that leaf
  # is derived purely from `map.pipeline`. Steps added to the *main* workflow
  # graph after the map are never on the `fan_out → fan_in` flow path that Runic
  # marks as "mapped" (per-element), so they are not executed per element.
  #
  # Therefore the only way to place a step between map and reduce is to extend
  # `map.pipeline` itself: appending here makes the last body step the pipeline's
  # leaf, which is exactly what the downstream reduce fans in from. In effect we
  # reconstruct at runtime what the `Runic.map` macro builds at compile time.
  #
  # COUPLING / RISK: this depends on Runic internals — the `Map` struct's
  # `:pipeline` field being a `Workflow`, and `connect/3`'s leaf semantics. Runic
  # is an alpha dependency (`~> 0.1.0-alpha.8`), so both could change without
  # notice; pin the version and re-verify the region tests on any Runic bump.
  # `mapper.closure`/`mapper.hash` are left describing only the original
  # single-fn map and are intentionally NOT updated — `connect/3` reads
  # `map.pipeline`, not the closure, and hermitscale rehydrates by recompiling
  # from the stored graph JSON rather than from a serialized Runic struct, so the
  # stale closure is never consulted. The proper fix is an upstream runtime
  # builder (e.g. `Runic.Workflow.Map.add_step/3`); until then this is the gap.
  defp append_map_pipeline(mapper, body_ids, compile_context) do
    pipeline =
      Enum.reduce(body_ids, mapper.pipeline, fn id, pipeline ->
        Workflow.add_step(
          pipeline,
          pipeline_leaf(pipeline),
          build_region_step(id, previous_id(id, compile_context), compile_context)
        )
      end)

    %{mapper | pipeline: pipeline}
  end

  defp pipeline_leaf(pipeline) do
    pipeline
    |> pipeline_leaves()
    |> case do
      [leaf] ->
        leaf

      leaves ->
        raise ArgumentError, "map pipeline must have exactly one leaf, got #{length(leaves)}"
    end
  end

  defp pipeline_leaves(pipeline) do
    pipeline
    |> pipeline_nodes()
    |> Enum.reject(&(Workflow.next_steps(pipeline, &1) != []))
  end

  defp pipeline_nodes(pipeline), do: walk_pipeline(pipeline, Workflow.root(), MapSet.new())

  defp walk_pipeline(pipeline, node, seen) do
    if MapSet.member?(seen, node) do
      []
    else
      seen = MapSet.put(seen, node)

      pipeline
      |> Workflow.next_steps(node)
      |> Enum.flat_map(fn child -> [child | walk_pipeline(pipeline, child, seen)] end)
    end
  end

  defp previous_id(id, compile_context) do
    compile_context.main_parents
    |> Map.fetch!(id)
    |> List.first()
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

  defp reduce_output(workflow, reduce_id) do
    workflow
    |> Workflow.get_component!({reduce_id, :fan_in})
    |> List.first()
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

  defp add_node_policies(workflow, ids, compile_context) do
    Enum.reduce(ids, workflow, &add_node_policy(&2, &1, compile_context))
  end

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
