defmodule Runic.Workflow.FanIn do
  @moduledoc """
  FanIn steps are part of a reduce operator that combines multiple facts into a single fact
  by applying the reducer function to return the accumulator with the parent.

  ## Options

  - `:mergeable` - When `true`, indicates this fan-in's reducer has CRDT-like
    properties (commutative, idempotent, associative) and is safe for parallel merge
    without ordering guarantees. Defaults to `false`.

  ## Runtime Context

  FanIn supports `meta_refs` for `context/1` when used as part of a reduce
  operation. The `has_meta_refs?/1` function indicates whether context
  references are present.
  """
  defstruct [:hash, :init, :reducer, :map, :name, mergeable: false, meta_refs: []]

  @doc """
  Returns whether this FanIn has meta references (e.g., `context/1`)
  that need to be resolved during the prepare phase.
  """
  def has_meta_refs?(%__MODULE__{meta_refs: meta_refs}), do: meta_refs != []

  @doc """
  Builds a `%FanIn{}` from runtime values (no macro required).

  Options: `:reducer` (`(value, acc) -> acc`, required), `:init` (0-arity fun or
  literal, default `fn -> nil end`), `:name`, `:mergeable`, `:meta_refs`.
  Bind it to its fan-out with `Runic.Workflow.attach_fan_in/4`.
  """
  def new(opts) do
    reducer = opts[:reducer] || raise ArgumentError, "fan_in requires a :reducer"
    init = Keyword.get(opts, :init)
    init_fun = if is_function(init, 0), do: init, else: fn -> init end
    name = opts[:name]

    %__MODULE__{
      init: init_fun,
      reducer: reducer,
      name: name,
      map: opts[:map],
      mergeable: Keyword.get(opts, :mergeable, false),
      meta_refs: opts[:meta_refs] || [],
      hash: opts[:hash] || Runic.Workflow.Components.fact_hash({:fan_in, name})
    }
  end
end

defimpl Runic.Component, for: Runic.Workflow.FanIn do
  def hash(fan_in), do: fan_in.hash
  def source(_fan_in), do: nil
  def connectable?(_fan_in, _other), do: true
  def inputs(_fan_in), do: [items: [type: :any, cardinality: :many, doc: "Per-element results"]]
  def outputs(_fan_in), do: [result: [type: :any, doc: "Reduced value"]]

  # Bare connect only places the node; use Runic.Workflow.attach_fan_in/4 to also
  # draw the structural :fan_in binding to its fan-out.
  def connect(fan_in, to, workflow) do
    Runic.Workflow.add_step(workflow, to, fan_in)
  end
end

defimpl Runic.Workflow.Coordinator, for: Runic.Workflow.FanIn do
  @moduledoc false
  # Fan-in completion is a function of the fact DAG, not of any build-order
  # `mapped` cache. When the FanIn is scheduled by a per-element result arriving,
  # `finalize/3` recomputes — from the graph — whether every element the upstream
  # FanOut emitted for this batch has produced a result. If so it reduces them in
  # `meta.index` order and produces one fact. Idempotent via the `:reduced` edge.
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, FanIn, FanOut, Runnable, Private}
  alias Runic.Workflow.Events.{FactProduced, ActivationConsumed}

  def finalize(
        %FanIn{} = fan_in,
        %Workflow{graph: g} = wf,
        %Runnable{input_fact: fact, context: %{fan_in_context: %{mode: :fan_out_reduce}} = ctx}
      ) do
    fan_out = upstream_fan_out(g, fan_in)
    source_hash = source_fact_hash(g, fan_out, fact)

    cond do
      is_nil(fan_out) or is_nil(source_hash) -> {wf, []}
      already_reduced?(g, fan_in, source_hash) -> {wf, []}
      true -> maybe_complete(fan_in, wf, fan_out, source_hash, ctx)
    end
  end

  # Simple reduce mode (no upstream FanOut) is handled entirely in execute/2.
  def finalize(%FanIn{}, %Workflow{} = wf, %Runnable{}), do: {wf, []}

  defp maybe_complete(%FanIn{} = fan_in, %Workflow{graph: g} = wf, fan_out, source_hash, %{input_fact: fact} = ctx) do
    facts = fact_index(g)

    # expected: the element facts this FanOut emitted for this source fact
    expected =
      g
      |> Multigraph.out_edges(fan_out, by: :fan_out)
      |> Enum.map(& &1.v2)
      |> Enum.filter(&match?(%Fact{ancestry: {_s, ^source_hash}}, &1))
      |> length()

    # arrived: terminal results reaching this FanIn's flow-parents, correlated
    # back to an element fact of this source by walking ancestry.
    correlated =
      g
      |> Multigraph.in_edges(fan_in, by: :flow)
      |> Enum.map(& &1.v1)
      |> Enum.flat_map(fn leaf ->
        Multigraph.out_edges(g, leaf, by: :produced) |> Enum.map(& &1.v2)
      end)
      |> Enum.map(fn t -> {origin_element(facts, fan_out.hash, t), t} end)
      |> Enum.filter(fn {origin, _t} -> match?(%Fact{ancestry: {_s, ^source_hash}}, origin) end)

    if expected > 0 and length(correlated) == expected do
      effective_context = merge_effective_context(ctx.meta_context, ctx.run_context)

      reduced_value =
        correlated
        |> Enum.sort_by(fn {origin, _t} -> Map.get(origin.meta || %{}, :index, 0) end)
        |> Enum.map(fn {_o, t} -> t.value end)
        |> reduce_with_context(fan_in.init.(), fan_in.reducer, effective_context)

      reduced_fact = Fact.new(value: reduced_value, ancestry: {fan_in.hash, source_hash})

      # Consume every per-element arrival's activation into this fan_in (not just
      # the one that triggered finalize) so no stray :runnable edges linger when a
      # runner dispatches the fan_in once per batch rather than once per arrival.
      sister_consumed =
        for {_o, t} <- correlated, t.hash != fact.hash do
          %ActivationConsumed{fact_hash: t.hash, node_hash: fan_in.hash, from_label: :runnable}
        end

      produced = %FactProduced{
        hash: reduced_fact.hash,
        value: reduced_fact.value,
        ancestry: reduced_fact.ancestry,
        producer_label: :reduced,
        weight: ctx.ancestry_depth + 1
      }

      derived = sister_consumed ++ [produced]

      wf = Workflow.run_before_hooks(wf, fan_in, reduced_fact)
      wf = Enum.reduce(derived, wf, fn e, w -> Workflow.apply_event(w, e) end)
      wf = Workflow.run_after_hooks(wf, fan_in, reduced_fact)

      wf =
        wf
        |> Workflow.next_steps(fan_in)
        |> Enum.reduce(wf, fn step, w ->
          Workflow.draw_connection(w, reduced_fact, step, Private.connection_for_activatable(step))
        end)

      {wf, derived}
    else
      {wf, []}
    end
  end

  defp upstream_fan_out(g, fan_in) do
    g
    |> Multigraph.in_edges(fan_in, by: :fan_in)
    |> List.first(%{})
    |> Map.get(:v1)
  end

  # already produced a :reduced fact for this batch?
  defp already_reduced?(_g, _fan_in, nil), do: false

  defp already_reduced?(g, fan_in, source_hash) do
    g
    |> Multigraph.out_edges(fan_in, by: :reduced)
    |> Enum.any?(&match?(%Fact{ancestry: {_fan_in, ^source_hash}}, &1.v2))
  end

  # walk `fact`'s ancestry to the element fact emitted by `fan_out_hash`;
  # its parent is the source fact the FanOut split.
  defp source_fact_hash(_g, nil, _fact), do: nil

  defp source_fact_hash(g, %FanOut{hash: fan_out_hash}, %Fact{} = fact) do
    case origin_element(fact_index(g), fan_out_hash, fact) do
      %Fact{ancestry: {_fan_out, source_hash}} -> source_hash
      _ -> nil
    end
  end

  defp origin_element(_facts, fan_out_hash, %Fact{ancestry: {fan_out_hash, _source}} = fact),
    do: fact

  defp origin_element(facts, fan_out_hash, %Fact{ancestry: {_producer, parent_hash}}) do
    case Map.get(facts, parent_hash) do
      %Fact{} = parent -> origin_element(facts, fan_out_hash, parent)
      _ -> nil
    end
  end

  defp origin_element(_facts, _fan_out_hash, _), do: nil

  defp fact_index(g) do
    Multigraph.edges(g, by: [:produced, :fan_out, :reduced])
    |> Enum.flat_map(fn e -> [e.v1, e.v2] end)
    |> Enum.filter(&match?(%Fact{}, &1))
    |> Map.new(fn f -> {f.hash, f} end)
  end

  defp merge_effective_context(meta, run) when map_size(meta) == 0 and map_size(run) == 0, do: %{}
  defp merge_effective_context(meta, run) when map_size(run) == 0, do: meta
  defp merge_effective_context(meta, run) when map_size(meta) == 0, do: run
  defp merge_effective_context(meta, run), do: Map.merge(run, meta)

  defp reduce_with_context(enumerable, acc, reducer, effective_context) do
    arity = Function.info(reducer, :arity) |> elem(1)

    Enum.reduce_while(enumerable, acc, fn value, acc ->
      result =
        if effective_context != %{} and arity == 3 do
          reducer.(value, acc, effective_context)
        else
          reducer.(value, acc)
        end

      case result do
        {:cont, new_acc} -> {:cont, new_acc}
        {:halt, new_acc} -> {:halt, new_acc}
        new_acc -> {:cont, new_acc}
      end
    end)
  end
end
