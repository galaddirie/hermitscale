defmodule Hermitscale.Integrations.Google.Sheets.ClientTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Integrations.Google.Sheets.Client

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  describe "read_rows/4" do
    test "requests spreadsheet values with bearer auth" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v4/spreadsheets/sheet_123/values/Sheet1%21A%3AB"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer access_123"]

        Req.Test.json(conn, %{"values" => [["sku", "qty"], ["ABC", 2]]})
      end)

      assert {:ok, %{"values" => [["sku", "qty"], ["ABC", 2]]}} =
               Client.read_rows(
                 Hermitscale.WorkflowsFixtures.credential_reference_fixture(),
                 "sheet_123",
                 "Sheet1!A:B",
                 plug: {Req.Test, __MODULE__}
               )
    end

    test "accepts an empty sheet and JSON scalar cell values" do
      for body <- [
            %{"range" => "Sheet1!A:B"},
            %{"values" => []},
            %{"values" => [["sku", "qty"], ["ABC", 2, 1.5, true, false, nil, ""]]}
          ] do
        Req.Test.expect(__MODULE__, &Req.Test.json(&1, body))

        assert {:ok, ^body} =
                 Client.read_rows(
                   Hermitscale.WorkflowsFixtures.credential_reference_fixture(),
                   "sheet_123",
                   "Sheet1!A:B",
                   plug: {Req.Test, __MODULE__}
                 )
      end
    end

    test "malformed successful responses return a dependency error without reflecting content" do
      for body <- [
            "opaque-provider-secret",
            [],
            nil,
            false,
            %{"values" => nil},
            %{"values" => "opaque-provider-secret"},
            %{"values" => ["opaque-provider-secret"]},
            %{"values" => [["sku"], false]},
            %{"values" => [[%{"secret" => "opaque-provider-secret"}]]},
            %{"values" => [[["nested"]]]}
          ] do
        Req.Test.expect(__MODULE__, &Req.Test.json(&1, body))

        assert {:error, :invalid_google_sheets_response} =
                 Client.read_rows(
                   Hermitscale.WorkflowsFixtures.credential_reference_fixture(),
                   "sheet_123",
                   "Sheet1!A:B",
                   plug: {Req.Test, __MODULE__}
                 )
      end
    end
  end

  describe "append_row/5" do
    test "posts row values with user-entered input option" do
      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert conn.method == "POST"
        assert conn.request_path == "/v4/spreadsheets/sheet_123/values/Sheet1%21A%3AB:append"
        assert conn.query_string == "valueInputOption=USER_ENTERED"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer access_123"]
        assert Jason.decode!(body) == %{"values" => [["ABC", 2]]}

        Req.Test.json(conn, %{"updates" => %{"updatedRows" => 1}})
      end)

      assert {:ok, %{"updates" => %{"updatedRows" => 1}}} =
               Client.append_row(
                 Hermitscale.WorkflowsFixtures.credential_reference_fixture(),
                 "sheet_123",
                 "Sheet1!A:B",
                 ["ABC", 2],
                 plug: {Req.Test, __MODULE__}
               )
    end
  end
end
