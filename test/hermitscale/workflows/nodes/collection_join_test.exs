defmodule Hermitscale.Workflows.Nodes.CollectionJoinTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Workflows.Nodes.Builtin.Merge.V1, as: Merge

  describe "explicit collection joins" do
    test "zip modes have predictable behavior for unequal lengths" do
      inputs = [[1, 2, 3], [:a]]
      assert Merge.work(%{mode: "zip_nil"}, inputs, %{}) == [[1, :a], [2, nil], [3, nil]]
      assert Merge.work(%{mode: "zip_shortest"}, inputs, %{}) == [[1, :a]]
      assert Merge.work(%{mode: "zip_cycle"}, inputs, %{}) == [[1, :a], [2, :a], [3, :a]]
    end

    test "empty branches remain meaningful in each collection mode" do
      inputs = [[1, 2], []]
      assert Merge.work(%{mode: "zip_nil"}, inputs, %{}) == [[1, nil], [2, nil]]
      assert Merge.work(%{mode: "zip_cycle"}, inputs, %{}) == [[1, nil], [2, nil]]
      assert Merge.work(%{mode: "zip_shortest"}, inputs, %{}) == []
      assert Merge.work(%{mode: "cartesian"}, inputs, %{}) == []
      assert Merge.work(%{mode: "zip_nil"}, [[], []], %{}) == []
    end

    test "cartesian products and flatten preserve nested payloads and duplicate occurrences" do
      assert Merge.work(%{mode: "cartesian"}, [[1, 1], [:a, :b]], %{}) ==
               [[1, :a], [1, :b], [1, :a], [1, :b]]

      assert Merge.work(%{mode: "flatten"}, [[[1, 2]], [[3]]], %{}) == [[1, 2], [3]]
      assert Merge.work(%{mode: "append"}, [[1], [2, 3]], %{}) == [[1], [2, 3]]
    end

    test "collection modes fail explicitly for scalar branches" do
      for mode <- ~w(zip_nil zip_shortest zip_cycle cartesian flatten) do
        assert_raise ArgumentError, ~r/collection join requires list inputs/, fn ->
          Merge.work(%{mode: mode}, [[1], 2], %{})
        end
      end
    end
  end
end
