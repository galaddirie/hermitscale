defmodule Hermitscale.Triggers.Google.Sheets.RowChangeTest do
  use ExUnit.Case, async: false

  alias Hermitscale.Triggers.Google.Sheets.RowChange
  alias Hermitscale.Workflows.Nodes.Params

  @ctx %{
    trigger_id: "t_1",
    graph_id: "g_1",
    credentials: Hermitscale.WorkflowsFixtures.credential_reference_fixture()
  }

  setup do
    previous = Application.get_env(:hermitscale, :google_sheets_req_options, [])

    Application.put_env(:hermitscale, :google_sheets_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    on_exit(fn -> Application.put_env(:hermitscale, :google_sheets_req_options, previous) end)
    :ok
  end

  defp params(overrides \\ %{}) do
    spec = RowChange.V1.spec()

    %{"spreadsheet_id" => "sheet_1"}
    |> Map.merge(overrides)
    |> Params.cast!(spec.params_schema, [], [])
  end

  defp stub_values(values) do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"values" => values})
    end)
  end

  test "init_cursor snapshots the sheet into a row index" do
    stub_values([["id", "name"], ["1", "ada"]])

    assert {:ok, %{"rows" => rows}} = RowChange.V1.init_cursor(params(), @ctx)
    assert map_size(rows) == 1
    assert Map.has_key?(rows, "row:2")
  end

  test "requests the sheet-qualified range with bearer auth" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v4/spreadsheets/sheet_1/values/Orders%21A%3AC"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer access_123"]
      Req.Test.json(conn, %{"values" => []})
    end)

    assert {:ok, _cursor} =
             RowChange.V1.init_cursor(params(%{"sheet" => "Orders", "range" => "A:C"}), @ctx)
  end

  test "an appended row fires row_added with header-keyed values" do
    stub_values([["id", "name"], ["1", "ada"]])
    {:ok, cursor} = RowChange.V1.init_cursor(params(), @ctx)

    stub_values([["id", "name"], ["1", "ada"], ["2", "grace"]])
    assert {:ok, [event], cursor} = RowChange.V1.poll(params(), cursor, @ctx)

    assert "row_added:row:3:" <> hash = event.key
    assert byte_size(hash) == 16
    assert event.payload["change_type"] == "row_added"
    assert event.payload["row_number"] == 3
    assert event.payload["values"] == %{"id" => "2", "name" => "grace"}
    assert event.payload["spreadsheet_id"] == "sheet_1"

    # Nothing new on the next poll: same snapshot, no events.
    assert {:ok, [], _cursor} = RowChange.V1.poll(params(), cursor, @ctx)
  end

  test "a changed cell fires row_updated" do
    stub_values([["id", "name"], ["1", "ada"]])
    {:ok, cursor} = RowChange.V1.init_cursor(params(), @ctx)

    stub_values([["id", "name"], ["1", "lovelace"]])
    assert {:ok, [event], _cursor} = RowChange.V1.poll(params(), cursor, @ctx)

    assert event.payload["change_type"] == "row_updated"
    assert event.payload["values"]["name"] == "lovelace"
  end

  test "the event param filters change types" do
    stub_values([["id", "name"], ["1", "ada"]])
    {:ok, cursor} = RowChange.V1.init_cursor(params(%{"event" => "row_added"}), @ctx)

    stub_values([["id", "name"], ["1", "lovelace"], ["2", "grace"]])

    assert {:ok, [event], _cursor} =
             RowChange.V1.poll(params(%{"event" => "row_added"}), cursor, @ctx)

    assert event.payload["change_type"] == "row_added"
    assert event.payload["values"]["id"] == "2"
  end

  test "missing credentials fail the poll rather than crash it" do
    ctx = %{@ctx | credentials: nil}
    assert {:error, :missing_credentials} = RowChange.V1.init_cursor(params(), ctx)
    assert {:error, :missing_credentials} = RowChange.V1.poll(params(), %{}, ctx)
  end

  test "API failures surface as poll errors" do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert {:error, {:google_sheets_request_failed, 500}} =
             RowChange.V1.poll(params(), %{"rows" => %{}}, @ctx)
  end

  test "validate_params bounds the poll interval and row layout" do
    assert :ok = RowChange.V1.validate_params(params())

    assert {:error, message} =
             RowChange.V1.validate_params(params(%{"poll_interval_ms" => 5_000}))

    assert message =~ "poll_interval_ms"

    assert {:error, message} =
             RowChange.V1.validate_params(params(%{"header_row" => 3, "first_data_row" => 2}))

    assert message =~ "first_data_row"
  end
end
