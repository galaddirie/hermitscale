defmodule Hermitscale.Workflows.Compiler do
  @moduledoc """
  Compiles validated graph definitions into native Runic workflows.

  Collection scopes determine where maps, joins and collectors belong;
  all catalog nodes otherwise share the same compilation path.
  """

  alias Hermitscale.Workflows.{Catalog, CollectionScopes, Policy, Topology, Validator}
  alias Hermitscale.Workflows.Engine.{FanIn, FanOut, Join}
  alias Hermitscale.Workflows.Nodes.Params
  alias Runic.Workflow

  @doc "Compiles a graph into an executable Runic workflow."
  def compile(graph) do
    with :ok <- Validator.validate(graph),
         {:ok, order} <- Topology.order(graph) do
      nodes = Map.new(Validator.node_specs(graph), &{&1["id"], &1})
      catalog = Catalog.index()

      modules =
        Map.new(nodes, fn {id, node} ->
          {id, Catalog.fetch!(catalog, node["type"], node["version"])}
        end)

      specs = Map.new(modules, fn {id, module} -> {id, module.__catalog_node__()} end)
      kinds = Map.new(specs, fn {id, spec} -> {id, spec.kind} end)
      {:ok, scopes} = CollectionScopes.analyze(graph, kinds)

      context = %{
        ambient: expression_runtime(graph),
        modules: modules,
        nodes: nodes,
        parents: Topology.parent_map(Map.fetch!(graph, "connections")),
        scopes: scopes,
        specs: specs
      }

      workflow =
        graph
        |> base_workflow(context.ambient)
        |> then(fn workflow -> Enum.reduce(order, workflow, &compile_node(&1, &2, context)) end)

      {:ok, workflow}
    end
  end

  @doc "Compiles a graph or raises on validation errors."
  def compile!(graph) do
    case compile(graph) do
      {:ok, workflow} -> workflow
      {:error, issues} -> raise ArgumentError, "invalid workflow graph: #{inspect(issues)}"
    end
  end

  defp compile_node(id, workflow, context) do
    module = Map.fetch!(context.modules, id)
    spec = Map.fetch!(context.specs, id)
    node_spec = Map.fetch!(context.nodes, id)
    parents = Map.get(context.parents, id, [])
    scope = Map.fetch!(context.scopes, id)

    params =
      Params.cast!(
        Map.get(node_spec, "params", %{}),
        spec.params_schema,
        spec.expr_fields,
        spec.predicate_fields
      )

    node =
      module.build(params, %{
        name: id,
        parents: parents,
        map: scope.map
      })

    {workflow, inputs} = prepare_inputs(workflow, spec.kind, id, parents, scope)

    workflow
    |> add_node(node, inputs)
    |> add_policy(node_spec, spec)
  end

  defp prepare_inputs(workflow, :map, id, parents, _scope) do
    fan_out = FanOut.new("#{id}$fanout", id)
    {add_node(workflow, fan_out, parents), [fan_out.name]}
  end

  defp prepare_inputs(workflow, kind, id, parents, scope) when kind in [:reduce, :aggregate] do
    [parent] = parent_hashes(workflow, parents)
    fan_in = FanIn.new("#{id}$fanin", parent, scope.map)
    {add_node(workflow, fan_in, parents), [fan_in.name]}
  end

  defp prepare_inputs(workflow, :join, id, parents, _scope) do
    join = Join.new("#{id}$join", parent_hashes(workflow, parents))
    {add_node(workflow, join, parents), [join.name]}
  end

  defp prepare_inputs(workflow, _kind, _id, parents, _scope), do: {workflow, parents}

  defp parent_hashes(workflow, parents),
    do: Enum.map(parents, &Workflow.get_component!(workflow, &1).hash)

  defp add_node(workflow, node, []), do: Workflow.add(workflow, node, log: false)

  defp add_node(workflow, node, [parent]),
    do: Workflow.add(workflow, node, to: parent, log: false)

  defp add_node(workflow, node, parents),
    do: Workflow.add(workflow, node, to: parents, log: false)

  defp add_policy(workflow, %{"id" => id} = node_spec, spec) do
    policy =
      spec.default_policy
      |> Map.merge(Policy.normalize(Map.get(node_spec, "policy", %{})))
      |> Policy.execution()

    case map_size(policy) do
      0 -> workflow
      _ -> Workflow.add_scheduler_policy(workflow, {:name, exact_name(id)}, policy)
    end
  end

  defp exact_name(id), do: Regex.compile!("\\A#{Regex.escape(id)}\\z")

  defp base_workflow(graph, ambient) do
    graph
    |> Map.fetch!("name")
    |> then(&Workflow.new(name: &1))
    |> Workflow.put_run_context(%{_global: %{_expr: ambient}})
  end

  defp expression_runtime(graph) do
    %{
      env: Map.get(graph, "env", %{}),
      execution: %{},
      vars: Map.get(graph, "vars", %{}),
      workflow: %{"id" => Map.fetch!(graph, "id"), "name" => Map.fetch!(graph, "name")}
    }
  end
end
