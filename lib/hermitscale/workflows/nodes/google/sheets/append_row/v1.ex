defmodule Hermitscale.Workflows.Nodes.Google.Sheets.AppendRow.V1 do
  @moduledoc false

  use Hermitscale.Integrations.Google,
    id: "google.sheets.append_row",
    version: 1,
    kind: :step,
    scopes: ["https://www.googleapis.com/auth/spreadsheets"],
    params: [
      spreadsheet_id: [type: :string, required: true, doc: "Target spreadsheet id."],
      range: [type: :string, default: "Sheet1!A:Z", doc: "A1 range to append after."]
    ]

  require Runic

  alias Hermitscale.Integrations.Google.Sheets.Client

  @impl true
  def build(%{spreadsheet_id: spreadsheet_id, range: range}, %{name: name}) do
    Runic.step(
      fn input ->
        case Client.append_row(context(:credentials), ^spreadsheet_id, ^range, input) do
          {:ok, body} -> body
          {:error, reason} -> raise "Google Sheets append row failed: #{inspect(reason)}"
        end
      end,
      name: name
    )
  end
end
