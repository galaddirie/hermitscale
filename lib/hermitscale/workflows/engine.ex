defmodule Hermitscale.Workflows.Engine do
  @moduledoc "Public result and completion projections for the Runic-backed workflow engine."

  alias Hermitscale.Workflows.Engine.{FanIn, Join}
  alias Runic.Identity
  alias Runic.Workflow
  alias Runic.Workflow.Fact

  @doc "Builds an explicit input occurrence, including nil payloads, for a durable run."
  def input(value, occurrence) do
    Fact.new(value: value, id: Identity.derive(:fact_occurrence, %{workflow_input: occurrence}))
  end

  @doc "Returns successful payloads in deterministic item order, excluding control outcomes."
  def productions(%Workflow{} = workflow, name) do
    workflow
    |> Workflow.productions(name)
    |> Enum.filter(&successful?/1)
    |> Enum.sort_by(&order/1)
    |> Enum.map(& &1.value)
  end

  @doc "Rejects idle workflows that still have unsatisfied collection or join inputs."
  def completion(%Workflow{} = workflow) do
    pending =
      workflow.graph
      |> Multigraph.edges(by: :joined)
      |> Enum.flat_map(fn
        %{v2: %Join{name: name}} -> [name]
        %{v2: %FanIn{name: name}} -> [name]
        _edge -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()

    case pending do
      [] -> :ok
      nodes -> {:error, %{"reason" => "incomplete_collection", "nodes" => nodes}}
    end
  end

  defp successful?(%{meta: %{hermitscale: %{status: :ok}}}), do: true

  defp successful?(%{meta: %{hermitscale: %{status: status}}}) when status in [:empty, :skipped],
    do: false

  defp successful?(%{meta: meta}), do: not Map.has_key?(meta, :hermitscale)

  defp order(fact) do
    case Map.fetch(fact.meta, :hermitscale) do
      {:ok, state} -> {state.root, Enum.map(state.frames, & &1.index), fact.hash}
      :error -> {fact.hash, [], fact.hash}
    end
  end
end
