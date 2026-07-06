defmodule Hermitscale.Triggers.Google.Sheets.RowsTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Triggers.Google.Sheets.Rows

  @params %{header_row: 1, first_data_row: 2, primary_key_column: nil}

  describe "parse/2" do
    test "maps data rows to header-keyed snapshots with positional keys" do
      values = [["id", "name"], ["1", "ada"], ["2", "grace"]]

      assert [first, second] = Rows.parse(values, @params)
      assert first.row_number == 2
      assert first.key == "row:2"
      assert first.values == %{"id" => "1", "name" => "ada"}
      assert first.raw == ["1", "ada"]
      assert second.key == "row:3"
    end

    test "uses the primary key column for row identity when configured" do
      values = [["id", "name"], ["u_1", "ada"]]
      params = %{@params | primary_key_column: "id"}

      assert [%{key: "pk:u_1"}] = Rows.parse(values, params)
    end

    test "falls back to positional identity when the primary key cell is blank" do
      values = [["id", "name"], ["", "ada"]]
      params = %{@params | primary_key_column: "id"}

      assert [%{key: "row:2"}] = Rows.parse(values, params)
    end

    test "names blank headers and cells beyond header width positionally" do
      values = [["id", ""], ["1", "ada", "extra"]]

      assert [%{values: values_map}] = Rows.parse(values, @params)
      assert values_map == %{"id" => "1", "column_2" => "ada", "column_3" => "extra"}
    end

    test "respects custom header and first data rows" do
      values = [["junk"], ["id", "name"], ["skip me"], ["1", "ada"]]
      params = %{@params | header_row: 2, first_data_row: 4}

      assert [%{row_number: 4, values: %{"id" => "1", "name" => "ada"}}] =
               Rows.parse(values, params)
    end
  end

  describe "diff/2" do
    test "detects additions, updates, and ignores unchanged and deleted rows" do
      before = Rows.parse([["id", "n"], ["a", "1"], ["b", "2"], ["c", "3"]], @params)
      previous = Rows.index(before)

      # b changes, c is deleted (d shifts into its position), e is appended.
      later = Rows.parse([["id", "n"], ["a", "1"], ["b", "9"], ["d", "4"], ["e", "5"]], @params)

      assert [{:updated, updated}, {:updated, shifted}, {:added, added}] =
               Rows.diff(later, previous)

      assert updated.values["n"] == "9"
      assert shifted.values["id"] == "d"
      assert added.values["id"] == "e"
    end

    test "with a primary key, deletes do not read as updates of shifted rows" do
      params = %{@params | primary_key_column: "id"}
      before = Rows.parse([["id", "n"], ["a", "1"], ["b", "2"], ["c", "3"]], params)
      previous = Rows.index(before)

      later = Rows.parse([["id", "n"], ["a", "1"], ["c", "3"]], params)

      assert Rows.diff(later, previous) == []
    end
  end
end
