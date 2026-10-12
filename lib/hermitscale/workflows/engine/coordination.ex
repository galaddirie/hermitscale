defmodule Hermitscale.Workflows.Engine.Coordination do
  @moduledoc false

  alias Hermitscale.Workflows.Engine.{Collect, Join, Metadata}
  alias Runic.Workflow
  alias Runic.Workflow.{CausalContext, Fact, Private, Runnable}

  alias Runic.Workflow.Events.{
    ActivationConsumed,
    FactProduced,
    JoinEdgeRelabeled,
    JoinFactReceived
  }

  @doc false
  def prepare(node, workflow, fact) do
    Metadata.validate!(fact.meta)

    context =
      CausalContext.new(
        node_hash: node.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact)
      )

    {:ok, Runnable.new(node, fact, context)}
  end

  @doc false
  def execute(node, %Runnable{input_fact: fact, context: context} = runnable) do
    {parent, _source} = fact.ancestry

    events = [
      %JoinFactReceived{
        fact_hash: fact.hash,
        join_hash: node.hash,
        parent_hash: parent,
        weight: context.ancestry_depth + 1
      },
      %ActivationConsumed{fact_hash: fact.hash, node_hash: node.hash, from_label: :runnable}
    ]

    Runnable.complete(runnable, :waiting, events)
  end

  @doc false
  def invoke(node, workflow, fact) do
    {:ok, runnable} = prepare(node, workflow, fact)
    Workflow.apply_runnable(workflow, execute(node, runnable))
  end

  @doc false
  def finalize(node, workflow, %Runnable{input_fact: input}) do
    case Multigraph.edge(workflow.graph, input, node, :join_satisfied) do
      nil ->
        finalize_arrival(node, workflow, input)

      %Multigraph.Edge{} ->
        event = %JoinEdgeRelabeled{
          fact_hash: input.hash,
          join_hash: node.hash,
          from_label: :joined,
          to_label: :join_satisfied
        }

        {Workflow.apply_event(workflow, event), [event]}
    end
  end

  defp finalize_arrival(node, workflow, input) do
    key = correlation_key(node, input)

    edges =
      workflow.graph
      |> Multigraph.in_edges(node, by: :joined)
      |> Enum.filter(&(correlation_key(node, &1.v1) == key))

    case arrivals(node, edges) do
      :waiting ->
        {workflow, []}

      {:ready, facts} ->
        relabeled =
          Enum.map(edges, fn edge ->
            %JoinEdgeRelabeled{
              fact_hash: edge.v1.hash,
              join_hash: node.hash,
              from_label: :joined,
              to_label: :join_satisfied
            }
          end)

        if completed?(node, workflow, key) do
          {Workflow.apply_events(workflow, relabeled), relabeled}
        else
          fact = result_fact(node, workflow, facts, key)

          produced =
            FactProduced.new(fact,
              producer_label: :produced,
              weight: Enum.max(Enum.map(facts, &Workflow.ancestry_depth(workflow, &1))) + 1
            )

          events = [produced | relabeled]
          workflow = Workflow.apply_events(workflow, events)
          {workflow, activated} = Private.activate_downstream_with_events(workflow, node, fact)
          {workflow, events ++ activated}
        end
    end
  end

  defp correlation_key(%Join{}, fact) do
    state = fact |> Map.fetch!(:meta) |> Metadata.state()
    {state.root, Enum.map(state.frames, & &1.item)}
  end

  defp correlation_key(%Collect{map_id: map_id}, fact) do
    state = Metadata.state(fact.meta)
    {outer, %{map: ^map_id, batch: batch}} = collection_frame!(state.frames)
    {state.root, Enum.map(outer, & &1.item), batch}
  end

  defp arrivals(%Join{parents: parents}, edges) do
    by_parent =
      Enum.group_by(edges, fn %{v1: fact} -> elem(fact.ancestry, 0) end, & &1.v1)

    facts =
      Enum.map(parents, fn parent ->
        case Map.get(by_parent, parent, []) do
          [] ->
            nil

          [fact] ->
            fact

          duplicates ->
            raise ArgumentError,
                  "multiple branch results for one item: #{inspect(Enum.map(duplicates, & &1.hash))}"
        end
      end)

    if Enum.any?(facts, &is_nil/1), do: :waiting, else: {:ready, facts}
  end

  defp arrivals(%Collect{parent: parent}, edges) do
    facts = Enum.map(edges, & &1.v1)
    frames = Enum.map(facts, &(&1.meta |> Metadata.state() |> Map.fetch!(:frames) |> List.last()))
    sizes = Enum.uniq(Enum.map(frames, & &1.size))
    [size] = sizes

    Enum.each(facts, fn fact ->
      {^parent, _source} = fact.ancestry
    end)

    indexes = Enum.map(frames, & &1.index)

    cond do
      length(indexes) != length(Enum.uniq(indexes)) ->
        raise ArgumentError, "multiple collection results for one item index"

      size == 0 ->
        [_sentinel] = facts
        {:ready, facts}

      Enum.sort(indexes) == Enum.to_list(0..(size - 1)) ->
        {:ready,
         Enum.sort_by(
           facts,
           &(&1.meta
             |> Metadata.state()
             |> Map.fetch!(:frames)
             |> List.last()
             |> Map.fetch!(:index))
         )}

      true ->
        :waiting
    end
  end

  defp result_fact(node, workflow, facts, key) do
    [first | _] = facts
    metadata = Metadata.merge(Enum.map(facts, & &1.meta))
    state = Metadata.state(metadata)
    {value, state} = result(node, workflow, facts, state)

    state =
      state
      |> Map.put(:parents, Enum.map(facts, & &1.hash))
      |> Map.put(:coordination, %{node: node.hash, key: key})

    Fact.new(
      value: value,
      ancestry: {node.hash, first.hash},
      meta: Metadata.put_state(metadata, state)
    )
  end

  defp result(%Join{}, workflow, facts, state) do
    joined =
      Enum.map(facts, fn fact ->
        {producer, _source} = fact.ancestry
        node = Map.fetch!(workflow.graph.vertices, producer)
        status = Metadata.state(fact.meta).status

        %{value: fact.value, metadata: fact.meta, id: fact.hash, status: status, node: node.name}
      end)

    status = if Enum.any?(state.frames, &(&1.size == 0)), do: :empty, else: :ok
    {Enum.map(joined, & &1.value), state |> Map.put(:joined, joined) |> Map.put(:status, status)}
  end

  defp result(%Collect{}, _workflow, facts, state) do
    [first | _] = facts
    first_state = Metadata.state(first.meta)
    {outer, frame} = collection_frame!(first_state.frames)

    collected =
      if frame.size == 0 do
        []
      else
        Enum.map(facts, &%{value: &1.value, metadata: &1.meta, id: &1.hash})
      end

    status =
      cond do
        Enum.any?(outer, &(&1.size == 0)) -> :empty
        frame.size == 0 and first_state.status == :skipped -> :skipped
        true -> :ok
      end

    state =
      state
      |> Map.put(:frames, outer)
      |> Map.put(:collected, collected)
      |> Map.put(:status, status)

    {Enum.map(collected, & &1.value), state}
  end

  defp collection_frame!([_ | _] = frames) do
    {outer, [frame]} = Enum.split(frames, -1)
    {outer, frame}
  end

  defp completed?(node, workflow, key) do
    workflow.graph
    |> Multigraph.out_edges(node, by: :produced)
    |> Enum.any?(fn %{v2: fact} ->
      Metadata.state(fact.meta).coordination == %{node: node.hash, key: key}
    end)
  end
end
