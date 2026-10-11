defmodule RunicIterationMetadataProbe do
  require Runic
  import ExUnit.Assertions
  alias Runic.Workflow
  alias Runic.Workflow.Events.FanOutFactEmitted

  def build do
    Workflow.new()
    |> Workflow.add(
      Runic.map(
        {Runic.step(fn x -> x * 2 end, name: :double),
         [Runic.step(fn x -> x + 1 end, name: :increment)]},
        name: :numbers
      ),
      log: false
    )
    |> Workflow.add(
      Runic.reduce([], fn x, acc -> acc ++ [x] end, name: :collect, map: :numbers),
      to: :increment,
      log: false
    )
    |> Workflow.enable_event_emission()
  end

  # Read the fan-out occurrence coordinates, rather than collection positions
  # in the unordered productions list or coordinator bookkeeping.
  def rows(workflow, node_name) do
    [fan_out] = Workflow.get_component!(workflow, {:numbers, :fan_out})
    facts = Map.new(Workflow.facts(workflow), &{&1.hash, &1})

    workflow
    |> Workflow.productions(node_name)
    |> Enum.map(fn output ->
      item = origin(output, facts, fan_out.hash)
      %{iteration: item.causal_ancestry.output_index + 1,
        index: item.causal_ancestry.output_index,
        batch: item.causal_ancestry.parent_fact_id,
        item_id: item.hash,
        input: item.value,
        output: output.value}
    end)
    |> Enum.sort_by(& &1.index)
  end

  def total(workflow) do
    [fan_out] = Workflow.get_component!(workflow, {:numbers, :fan_out})
    workflow
    |> Workflow.facts()
    |> Enum.count(fn fact ->
      match?({producer, _} when producer == fan_out.hash, fact.ancestry)
    end)
  end

  defp origin(%{ancestry: {producer, _}} = fact, _facts, producer), do: fact
  defp origin(%{ancestry: {_, parent}}, facts, fan_out),
    do: origin(Map.fetch!(facts, parent), facts, fan_out)

  def run do
    input = [3, 1, 3, 2]
    executed = build() |> Workflow.react_until_satisfied(input)
    rows = rows(executed, :increment)
    assert Enum.map(rows, & &1.output) == [7, 3, 7, 5]
    assert Enum.find(rows, &(&1.iteration == 2)).output == 3
    assert total(executed) == 4
    assert length(Enum.uniq_by(rows, & &1.item_id)) == 4
    assert Workflow.raw_productions(executed, :collect) == [[7, 3, 7, 5]]

    # Expected-count/seen tables have been cleaned after the fold.
    [fan_out] = Workflow.get_component!(executed, {:numbers, :fan_out})
    assert Map.get(executed.mapped, {hd(rows).batch, fan_out.hash}) == nil
    events = Enum.reverse(executed.uncommitted_events)
    emitted = Enum.filter(events, &is_struct(&1, FanOutFactEmitted))
    assert length(emitted) == 4
    assert Enum.map(emitted, & &1.emitted_causal_ancestry.output_index) == [0, 1, 2, 3]

    replayed =
      events
      |> :erlang.term_to_binary()
      |> :erlang.binary_to_term([:safe])
      |> Workflow.from_events(build())
    assert rows(replayed, :increment) == rows
    assert total(replayed) == 4

    partial = build() |> Workflow.react(input, [])
    assert total(partial) == 4
    assert rows(partial, :increment) == []
    empty = build() |> Workflow.react_until_satisfied([])
    assert total(empty) == 0
    assert rows(empty, :increment) == []

    IO.inspect(%{iteration_2_output: 3, total_iterations: total(executed),
      ordered_outputs: Enum.map(rows, & &1.output), distinct_item_occurrences: length(rows),
      replay_preserves_rows_and_total: true, planned_before_body_finishes: total(partial),
      completed_before_body_finishes: length(rows(partial, :increment)), empty_total: total(empty)},
      label: "Verified main iteration metadata")
  end
end

RunicIterationMetadataProbe.run()
