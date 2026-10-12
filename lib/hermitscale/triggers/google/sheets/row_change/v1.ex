defmodule Hermitscale.Triggers.Google.Sheets.RowChange.V1 do
  @moduledoc """
  Trigger that fires when rows are added to (or changed in) a Google Sheet.

  Sheets offers no change feed, so this is a polling trigger: activation
  snapshots the sheet into the cursor (`init_cursor/2`), and every poll diffs
  the current rows against it — see `Hermitscale.Triggers.Google.Sheets.Rows`
  for identity and hashing semantics. Each event's idempotency key is
  `change_type + row key + content hash`, so replayed polls dedupe at the
  dispatcher.
  """

  use Hermitscale.Triggers.Behaviour,
    id: "google.sheets.row_change",
    version: 1,
    mode: :polling,
    requires: [
      credentials: [
        provider: "google",
        scopes: ["https://www.googleapis.com/auth/spreadsheets.readonly"]
      ]
    ],
    params: [
      spreadsheet_id: [type: :string, required: true, doc: "Target spreadsheet id."],
      sheet: [type: :string, default: "Sheet1", doc: "Sheet (tab) name."],
      range: [
        type: :string,
        default: "A:ZZZ",
        doc: "A1 range inside the sheet; a full `Sheet!A:B` range overrides `sheet`."
      ],
      event: [
        type: {:in, ~w(row_added row_updated row_added_or_updated)},
        default: "row_added_or_updated"
      ],
      header_row: [type: :pos_integer, default: 1],
      first_data_row: [type: :pos_integer, default: 2],
      primary_key_column: [
        type: :string,
        doc: "Optional stable column used to identify rows across inserts and re-sorts."
      ],
      poll_interval_ms: [type: :pos_integer, default: 60_000]
    ]

  alias Hermitscale.Integrations.Google.Sheets.Client
  alias Hermitscale.Triggers.Google.Sheets.Rows

  @min_poll_interval_ms 15_000

  @impl true
  def validate_params(params) do
    cond do
      params[:poll_interval_ms] < @min_poll_interval_ms ->
        {:error, "poll_interval_ms must be at least #{@min_poll_interval_ms}"}

      params[:first_data_row] <= params[:header_row] ->
        {:error, "first_data_row must be greater than header_row"}

      true ->
        :ok
    end
  end

  @impl true
  def init_cursor(params, ctx) do
    with {:ok, snapshots} <- read_rows(params, ctx) do
      {:ok, %{"rows" => Rows.index(snapshots)}}
    end
  end

  @impl true
  def poll(params, cursor, ctx) do
    with {:ok, snapshots} <- read_rows(params, ctx) do
      events =
        snapshots
        |> Rows.diff(cursor["rows"] || %{})
        |> Enum.filter(&selected?(&1, params.event))
        |> Enum.map(&to_event(&1, params))

      {:ok, events, %{"rows" => Rows.index(snapshots)}}
    end
  end

  defp read_rows(_params, %{credentials: nil}), do: {:error, :missing_credentials}

  defp read_rows(params, %{credentials: credentials}) do
    with {:ok, body} <- Client.read_rows(credentials, params.spreadsheet_id, range(params)) do
      {:ok, Rows.parse(body["values"] || [], params)}
    end
  end

  defp range(%{range: range, sheet: sheet}) do
    if String.contains?(range, "!"), do: range, else: "#{sheet}!#{range}"
  end

  defp selected?({:added, _snapshot}, event), do: event in ["row_added", "row_added_or_updated"]

  defp selected?({:updated, _snapshot}, event),
    do: event in ["row_updated", "row_added_or_updated"]

  defp to_event({change, snapshot}, params) do
    change_type = "row_#{change}"

    %{
      key: "#{change_type}:#{snapshot.key}:#{snapshot.hash}",
      payload: %{
        "spreadsheet_id" => params.spreadsheet_id,
        "sheet" => params.sheet,
        "change_type" => change_type,
        "row_number" => snapshot.row_number,
        "row_key" => snapshot.key,
        "values" => snapshot.values,
        "raw_values" => snapshot.raw,
        "detected_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
      }
    }
  end
end
