defmodule Hermitscale.Workflows.Nodes.Google.Sheets.BuiltinsTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Workflows.Nodes.Google.Sheets.AppendRow.V1, as: AppendRow
  alias Hermitscale.Workflows.Nodes.Google.Sheets.ReadRows.V1, as: ReadRows
  alias Hermitscale.Workflows.Nodes.Params

  describe "append_row v1" do
    test "casts params and builds a named step" do
      spec = AppendRow.spec()

      params =
        Params.cast!(
          %{"spreadsheet_id" => "sheet_123", "range" => "Sheet1!A:B"},
          spec.params_schema
        )

      step = AppendRow.build(params, %{name: "append", inputs: []})

      assert step.name == "append"
    end
  end

  describe "read_rows v1" do
    test "casts params and builds a named step" do
      spec = ReadRows.spec()

      params =
        Params.cast!(
          %{"spreadsheet_id" => "sheet_123", "range" => "Sheet1!A:B"},
          spec.params_schema
        )

      step = ReadRows.build(params, %{name: "read", inputs: []})

      assert step.name == "read"
    end
  end
end
