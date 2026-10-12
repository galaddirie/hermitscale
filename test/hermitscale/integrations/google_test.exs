defmodule Hermitscale.Integrations.GoogleTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Integrations.Provider
  alias Hermitscale.Workflows.Nodes.Google.Sheets.AppendRow.V1, as: AppendRow
  alias Hermitscale.Workflows.Nodes.Google.Sheets.ReadRows.V1, as: ReadRows

  describe "catalog node macro" do
    test "injects google credential requirements and default policy" do
      assert %{
               id: "google.sheets.append_row",
               requires: [
                 credentials: [
                   provider: "google",
                   scopes: ["https://www.googleapis.com/auth/spreadsheets"]
                 ]
               ],
               default_policy: %{
                 backoff: :exponential,
                 max_retries: 3,
                 timeout_ms: 30_000
               }
             } = AppendRow.spec()
    end

    test "registers the Google integration descriptor" do
      assert {:ok, Hermitscale.Integrations.Google} =
               Provider.fetch(Provider.refresh!(), "google")
    end

    test "declares read-only scopes for read rows" do
      assert [
               credentials: [
                 provider: "google",
                 scopes: ["https://www.googleapis.com/auth/spreadsheets.readonly"]
               ]
             ] = ReadRows.spec().requires
    end
  end
end
