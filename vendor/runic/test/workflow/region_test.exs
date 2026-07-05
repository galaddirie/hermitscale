defmodule Runic.Workflow.RegionTest do
  use ExUnit.Case, async: true

  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.{Step, FanOut, FanIn, Root}
  alias Runic.Workflow.Events.{FactProduced, ActivationConsumed}
  alias Runic.Workflow.Events.Serializer

  defp double, do: Step.new(work: fn x -> x * 2 end, name: :double)
  defp inc, do: Step.new(work: fn x -> x + 1 end, name: :inc)

  # fan_out(*2) -> inc(+1) -> fan_in(sum), built entirely from runtime values.
  defp sum_region(opts \\ []) do
    fan_out = FanOut.new(name: :nums)
    fan_in = FanIn.new(name: :sum, init: 0, reducer: &(&1 + &2))

    wf =
      Workflow.new(:pipeline)
      |> Workflow.attach_fan_out(fan_out, to: %Root{})
      |> Workflow.add_step(fan_out, double())
      |> Workflow.add_step(double(), inc())
      |> Workflow.attach_fan_in(fan_in, fan_out, from: inc())

    wf = if opts[:emit], do: Workflow.enable_event_emission(wf), else: wf
    {wf, fan_out, fan_in}
  end

  describe "fan_out -> step -> step -> fan_in (runtime-built, via react)" do
    test "reduces per-element results into one fact" do
      {wf, _fo, _fi} = sum_region()
      # ((1*2+1)+(2*2+1)+(3*2+1)+(4*2+1)) = 3+5+7+9 = 24
      assert [24] == wf |> Workflow.react_until_satisfied([1, 2, 3, 4]) |> Workflow.raw_productions(:sum)
    end

    test "reduces in deterministic emission order (meta.index), not arrival order" do
      fan_out = FanOut.new(name: :nums)
      fan_in = FanIn.new(name: :ordered, init: [], reducer: fn x, acc -> acc ++ [x] end)

      wf =
        Workflow.new(:pipeline)
        |> Workflow.attach_fan_out(fan_out, to: %Root{})
        |> Workflow.add_step(fan_out, double())
        |> Workflow.add_step(double(), inc())
        |> Workflow.attach_fan_in(fan_in, fan_out, from: inc())

      assert [[3, 5, 7, 9]] ==
               wf |> Workflow.react_until_satisfied([1, 2, 3, 4]) |> Workflow.raw_productions(:ordered)
    end

    test "keeps duplicate element values distinct (index-folded hashing)" do
      fan_out = FanOut.new(name: :nums)
      fan_in = FanIn.new(name: :sum, init: 0, reducer: &(&1 + &2))

      wf =
        Workflow.new(:pipeline)
        |> Workflow.attach_fan_out(fan_out, to: %Root{})
        |> Workflow.add_step(fan_out, inc())
        |> Workflow.attach_fan_in(fan_in, fan_out, from: inc())

      # inc over [2,2,3] = [3,3,4] -> sum 10 (would be 7 if the two 2s collided)
      assert [10] == wf |> Workflow.react_until_satisfied([2, 2, 3]) |> Workflow.raw_productions(:sum)
    end

    test "a step downstream of the fan_in runs once on the reduced (aggregate) fact" do
      fan_out = FanOut.new(name: :nums)
      fan_in = FanIn.new(name: :sum, init: 0, reducer: &(&1 + &2))
      label = Step.new(work: fn total -> {:total, total} end, name: :label)

      wf =
        Workflow.new(:pipeline)
        |> Workflow.attach_fan_out(fan_out, to: %Root{})
        |> Workflow.add_step(fan_out, double())
        |> Workflow.attach_fan_in(fan_in, fan_out, from: double())
        |> Workflow.add_step(fan_in, label)

      prods = wf |> Workflow.react_until_satisfied([1, 2, 3, 4]) |> Workflow.raw_productions()
      # doubles = [2,4,6,8], sum = 20, labeled exactly once on the aggregate fact
      assert Enum.count(prods, &(&1 == {:total, 20})) == 1
    end
  end

  describe "scope_of/2 — per-element scope is a topology query" do
    setup do
      fan_out = FanOut.new(name: :nums)
      fan_in = FanIn.new(name: :sum, init: 0, reducer: &(&1 + &2))
      d = double()
      i = inc()

      wf =
        Workflow.new(:pipeline)
        |> Workflow.attach_fan_out(fan_out, to: %Root{})
        |> Workflow.add_step(fan_out, d)
        |> Workflow.add_step(d, i)
        |> Workflow.attach_fan_in(fan_in, fan_out, from: i)

      %{wf: wf, fan_out: fan_out, fan_in: fan_in, d: d, i: i}
    end

    test "body steps are element-scoped; fan_in is aggregate", %{wf: wf, fan_out: fo, fan_in: fi, d: d, i: i} do
      assert {:element, hash} = Workflow.scope_of(wf, d)
      assert hash == fo.hash
      assert {:element, ^hash} = Workflow.scope_of(wf, i)
      assert :aggregate == Workflow.scope_of(wf, fi)
    end

    test "regions/1 lists the fan_out/fan_in pair", %{wf: wf, fan_out: fo, fan_in: fi} do
      assert [%{fan_out: found_fo, fan_in: found_fi}] = Workflow.regions(wf)
      assert found_fo.hash == fo.hash
      assert found_fi.hash == fi.hash
    end
  end

  describe "build-order independence" do
    test "binding the fan_in before the body still completes correctly" do
      fan_out = FanOut.new(name: :nums)
      fan_in = FanIn.new(name: :sum, init: 0, reducer: &(&1 + &2))

      wf =
        Workflow.new(:pipeline)
        |> Workflow.attach_fan_out(fan_out, to: %Root{})
        # structural binding drawn FIRST, before any body node exists
        |> Workflow.draw_connection(fan_out, fan_in, :fan_in)
        # ...then the body and the leaf->fan_in flow edge
        |> Workflow.add_step(fan_out, double())
        |> Workflow.add_step(double(), inc())
        |> Workflow.add_step(inc(), fan_in)

      assert 24 in (wf |> Workflow.react_until_satisfied([1, 2, 3, 4]) |> Workflow.raw_productions())
    end
  end

  describe "durable resume (recompile structure + replay event log)" do
    test "scattered element facts are FactProduced :fan_out and round-trip through ETF" do
      {wf, _fo, _fi} = sum_region(emit: true)
      reacted = Workflow.react_until_satisfied(wf, [1, 2, 3, 4])

      events = Enum.reverse(reacted.uncommitted_events)
      assert Enum.any?(events, &match?(%FactProduced{producer_label: :fan_out}, &1))

      assert {:ok, ^events} = events |> Serializer.to_binary() |> Serializer.from_binary()
    end

    test "replaying the full log onto a freshly recompiled structure restores the result" do
      {emitting, _fo, _fi} = sum_region(emit: true)
      reacted = Workflow.react_until_satisfied(emitting, [1, 2, 3, 4])
      log = reacted.uncommitted_events |> Enum.reverse()

      {fresh, _fo, _fi} = sum_region()
      restored = Workflow.from_events(log, fresh)

      assert [24] == Workflow.raw_productions(restored, :sum)
    end

    test "resuming MID-region re-derives fan-in completion from the replayed fact DAG" do
      {emitting, _fo, fan_in} = sum_region(emit: true)
      reacted = Workflow.react_until_satisfied(emitting, [1, 2, 3, 4])
      log = reacted.uncommitted_events |> Enum.reverse()

      # Simulate a crash after the per-element body finished but BEFORE the fan_in
      # committed: drop the fan_in's own outputs (its reduced FactProduced and its
      # ActivationConsumed marks), keep the pending activations into the fan_in.
      prefix =
        Enum.reject(log, fn
          %FactProduced{ancestry: {producer, _}} -> producer == fan_in.hash
          %ActivationConsumed{node_hash: node} -> node == fan_in.hash
          _ -> false
        end)

      {fresh, _fo, _fi} = sum_region()
      resumed = Workflow.from_events(prefix, fresh)

      # mid-region: the reduce has NOT happened yet...
      assert [] == Workflow.raw_productions(resumed, :sum)

      # ...continuing reaction completes the fan_in purely from the replayed DAG.
      assert [24] ==
               resumed |> Workflow.react_until_satisfied() |> Workflow.raw_productions(:sum)
    end
  end

  describe "trace/1,2 (n8n-style per-node input->output view)" do
    test "per-element iterations: one row per item, with index and input->output" do
      {wf, _fo, _fi} = sum_region()
      final = Workflow.react_until_satisfied(wf, [10, 20, 20])

      assert [
               %{index: 0, input: 10, output: 20},
               %{index: 1, input: 20, output: 40},
               %{index: 2, input: 20, output: 40}
             ] == Workflow.trace(final, :double)

      assert [
               %{index: 0, input: 20, output: 21},
               %{index: 1, input: 40, output: 41},
               %{index: 2, input: 40, output: 41}
             ] == Workflow.trace(final, :inc)

      # the fan-in shows the aggregate: whole input -> reduced output, no item index
      # double=[20,40,40] -> inc=[21,41,41] -> sum=103
      assert [%{index: nil, input: [10, 20, 20], output: 103}] == Workflow.trace(final, :sum)
    end

    test "works for plain (non-region) steps: single row each, index nil" do
      wf =
        Runic.workflow(
          steps: [
            {Runic.step(fn x -> x + 1 end, name: :a),
             [Runic.step(fn x -> x * 10 end, name: :b)]}
          ]
        )

      final = Workflow.react_until_satisfied(wf, 5)

      assert [%{index: nil, input: 5, output: 6}] == Workflow.trace(final, :a)
      assert [%{index: nil, input: 6, output: 60}] == Workflow.trace(final, :b)
    end

    test "trace/1 returns a map keyed by node name covering every producing node" do
      {wf, _fo, _fi} = sum_region()
      full = Workflow.react_until_satisfied(wf, [1, 2]) |> Workflow.trace()

      assert %{double: _, inc: _, sum: _, nums: _} = full
      # the fan-out node itself shows the split: whole input -> each element
      assert [%{index: 0, input: [1, 2], output: 1}, %{index: 1, input: [1, 2], output: 2}] ==
               full[:nums]
    end

    test "trace/2 for an unknown node returns []" do
      {wf, _fo, _fi} = sum_region()
      final = Workflow.react_until_satisfied(wf, [1])
      assert [] == Workflow.trace(final, :nonexistent)
    end
  end
end
