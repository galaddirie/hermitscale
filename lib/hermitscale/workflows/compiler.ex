defmodule Hermitscale.Workflows.Compiler do
  @moduledoc """
  Compiles validated workflow graph JSON into `Runic.Workflow` structs.
  """

  require Runic

  alias Hermitscale.Workflows.{Catalog, Policy, Validator}
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
    parents = Validator.parent_map(graph["connections"] || [])

    Enum.reduce(order, Runic.workflow(name: graph["name"]), fn id, workflow ->
      node_spec = Map.fetch!(nodes, id)
      module = Catalog.fetch!(catalog, node_spec["type"], node_spec["version"])
      spec = module.__catalog_node__()
      node_parents = Map.get(parents, id, [])
      params = Params.cast!(node_spec["params"] || %{}, spec.params_schema)

      node =
        module.build(params, %{
          name: id,
          inputs: node_parents
        })

      workflow
      |> add_node(node, node_parents)
      |> add_policy(node_spec, spec)
    end)
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
