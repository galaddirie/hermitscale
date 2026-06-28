defmodule Hermitscale.Workflows.Compiler do
  @moduledoc """
  Compiles validated workflow graph JSON into `Runic.Workflow` structs.
  """

  require Runic

  alias Hermitscale.Workflows.{Catalog, Validator}
  alias Runic.Workflow

  @backoff %{
    "none" => :none,
    "linear" => :linear,
    "exponential" => :exponential,
    "jitter" => :jitter
  }
  @on_failure %{"halt" => :halt, "skip" => :skip}
  @execution_mode %{"sync" => :sync, "async" => :async, "durable" => :durable}
  @priority %{"low" => :low, "normal" => :normal, "high" => :high, "critical" => :critical}

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

    workflow =
      Enum.reduce(order, Runic.workflow(name: graph["name"]), fn id, workflow ->
        node_spec = Map.fetch!(nodes, id)
        module = Catalog.fetch!(catalog, node_spec["type"], node_spec["version"])
        node_parents = Map.get(parents, id, [])

        node =
          module.build(node_spec["params"] || %{}, %{
            name: id,
            inputs: node_parents
          })

        add_node(workflow, node, node_parents)
      end)

    Enum.reduce(node_specs, workflow, &add_policy/2)
  end

  defp add_node(workflow, node, []), do: Workflow.add(workflow, node)

  defp add_node(workflow, node, [parent]),
    do: Workflow.add(workflow, node, to: parent)

  defp add_node(workflow, node, parents),
    do: Workflow.add(workflow, node, to: parents)

  defp add_policy(%{"id" => id, "policy" => policy}, workflow) when is_map(policy) do
    Workflow.add_scheduler_policy(workflow, {:name, exact_name(id)}, normalize_policy(policy))
  end

  defp add_policy(_node_spec, workflow), do: workflow

  defp exact_name(id), do: Regex.compile!("\\A#{Regex.escape(id)}\\z")

  defp normalize_policy(policy) do
    policy
    |> Enum.flat_map(&normalize_policy_entry/1)
    |> Map.new()
  end

  defp normalize_policy_entry({"backoff", value}), do: [backoff: Map.fetch!(@backoff, value)]

  defp normalize_policy_entry({"on_failure", value}),
    do: [on_failure: Map.fetch!(@on_failure, value)]

  defp normalize_policy_entry({"execution_mode", value}),
    do: [execution_mode: Map.fetch!(@execution_mode, value)]

  defp normalize_policy_entry({"priority", value}), do: [priority: Map.fetch!(@priority, value)]
  defp normalize_policy_entry({"max_retries", value}), do: [max_retries: value]
  defp normalize_policy_entry({"base_delay_ms", value}), do: [base_delay_ms: value]
  defp normalize_policy_entry({"max_delay_ms", value}), do: [max_delay_ms: value]
  defp normalize_policy_entry({"timeout_ms", value}), do: [timeout_ms: value]
  defp normalize_policy_entry({"deadline_ms", value}), do: [deadline_ms: value]
  defp normalize_policy_entry(_entry), do: []
end
