defmodule Hermitscale.Workflows.Nodes.Google.Sheets.ReadRows.V1 do
  @moduledoc false

  use Hermitscale.Integrations.Google,
    id: "google.sheets.read_rows",
    version: 1,
    kind: :step,
    scopes: ["https://www.googleapis.com/auth/spreadsheets.readonly"],
    params: [
      spreadsheet_id: [type: :string, required: true, doc: "Target spreadsheet id."],
      range: [type: :string, default: "Sheet1!A:Z", doc: "A1 range to read."]
    ]

  require Runic

  alias Hermitscale.Integrations.Google.Sheets.Client

  @impl true
  def build(%{spreadsheet_id: spreadsheet_id, range: range}, %{name: name}) do
    Runic.step(
      fn _input ->
        case Client.read_rows(context(:credentials), ^spreadsheet_id, ^range) do
          {:ok, body} -> body
          {:error, reason} -> raise "Google Sheets read rows failed: #{inspect(reason)}"
        end
      end,
      name: name
    )
  end
end
