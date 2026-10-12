defmodule Hermitscale.Workflows.Engine.FanOut do
  @moduledoc "Expands a collection into correlated item occurrences."

  alias Hermitscale.Workflows.Engine.Metadata
  alias Runic.Workflow
  alias Runic.Workflow.{CausalContext, Components, Fact, FactAncestry, Private, Runnable}
  alias Runic.Workflow.Events.{ActivationConsumed, FactProduced}

  @enforce_keys [:name, :map_id, :hash]
  defstruct [:name, :map_id, :hash]

  def new(name, map_id) do
    %__MODULE__{
      name: name,
      map_id: map_id,
      hash: Components.fact_hash({__MODULE__, name, map_id})
    }
  end

  @doc false
  def prepare(node, workflow, fact) do
    context =
      CausalContext.new(
        node_hash: node.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact)
      )

    {:ok, Runnable.new(node, fact, context)}
  end

  @doc false
  def execute(node, %Runnable{input_fact: source} = runnable) do
    metadata = Metadata.initialize(source)
    state = Metadata.state(metadata)

    case collection(source.value, state.status) do
      {:ok, values, status} ->
        size = length(values)
        indexed = if values == [], do: [{nil, 0}], else: Enum.with_index(values)

        facts =
          Enum.map(indexed, fn {value, index} ->
            ancestry =
              FactAncestry.from_legacy({node.hash, source.hash},
                activation_id: runnable.activation_id,
                output_port: :fan_out,
                output_index: index
              )

            fact =
              Fact.new(
                value: value,
                ancestry: {node.hash, source.hash},
                causal_ancestry: ancestry
              )

            frame = %{
              map: node.map_id,
              batch: source.hash,
              item: fact.hash,
              index: index,
              size: size,
              value: value
            }

            state = %{
              state
              | frames: state.frames ++ [frame],
                status: status,
                parents: [source.hash]
            }

            %{fact | meta: Metadata.put_state(metadata, state)}
          end)

        events =
          Enum.map(
            facts,
            &FactProduced.new(&1,
              producer_label: :produced,
              weight: runnable.context.ancestry_depth + 1
            )
          ) ++
            [
              %ActivationConsumed{
                fact_hash: source.hash,
                node_hash: node.hash,
                from_label: :runnable
              }
            ]

        Runnable.complete(runnable, facts, events)

      {:error, reason} ->
        Runnable.fail(runnable, reason)
    end
  end

  @doc false
  def invoke(node, workflow, fact) do
    {:ok, runnable} = prepare(node, workflow, fact)
    Workflow.apply_runnable(workflow, execute(node, runnable))
  end

  @doc false
  def activate(node, workflow, %Runnable{result: facts}) do
    {events, workflow} =
      Enum.flat_map_reduce(facts, workflow, fn fact, workflow ->
        {workflow, events} = Private.activate_downstream_with_events(workflow, node, fact)
        {events, workflow}
      end)

    {workflow, events}
  end

  defp collection(_value, :skipped), do: {:ok, [], :skipped}
  defp collection(_value, :empty), do: {:ok, [], :empty}
  defp collection(nil, :ok), do: {:ok, [], :empty}
  defp collection([], :ok), do: {:ok, [], :empty}
  defp collection(values, :ok) when is_list(values), do: {:ok, values, :ok}
  defp collection(value, :ok), do: {:error, {:expected_collection, value}}
end
