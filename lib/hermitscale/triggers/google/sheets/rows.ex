defmodule Hermitscale.Triggers.Google.Sheets.Rows do
  @moduledoc """
  Pure row parsing and change detection for the Sheets row-change trigger.

  Sheets has no change feed, so change detection is snapshot diffing: each
  data row gets a stable key and a content hash, the cursor stores the
  `key => hash` index from the previous poll, and a new snapshot is compared
  against it.

  Row identity:

    * With `primary_key_column` set, the key is that column's value — stable
      across row inserts, deletes, and re-sorting.
    * Without it, the key is the row's position. Inserting or deleting in the
      middle of the sheet shifts every row below it, which reads as updates;
      that is inherent to position-based identity, not a bug to fix here.

  Only the hash index is kept, never row contents, so cursor size stays
  bounded by row count (~30 bytes per row), not sheet width.
  """

  @hash_length 16

  @type snapshot :: %{
          row_number: pos_integer(),
          key: String.t(),
          hash: String.t(),
          values: %{String.t() => term()},
          raw: [term()]
        }

  @doc """
  Parses raw Sheets API values (list of row arrays) into row snapshots using
  the trigger's header/data-row/primary-key params.
  """
  @spec parse([[term()]], map()) :: [snapshot()]
  def parse(values, params) when is_list(values) do
    headers = headers(values, params)

    values
    |> Enum.drop(params.first_data_row - 1)
    |> Enum.with_index(params.first_data_row)
    |> Enum.map(fn {raw, row_number} ->
      values_map = zip_headers(headers, raw)

      %{
        row_number: row_number,
        key: row_key(values_map, row_number, params),
        hash: row_hash(raw),
        values: values_map,
        raw: raw
      }
    end)
  end

  @doc """
  The JSONB-safe `key => hash` index persisted as the poll cursor.
  """
  @spec index([snapshot()]) :: %{String.t() => String.t()}
  def index(snapshots), do: Map.new(snapshots, &{&1.key, &1.hash})

  @doc """
  Diffs snapshots against the previous cursor index. Rows whose key is new
  are `:added`; rows whose content hash changed are `:updated`. Disappeared
  rows produce no event (they simply leave the next index).
  """
  @spec diff([snapshot()], %{String.t() => String.t()}) :: [{:added | :updated, snapshot()}]
  def diff(snapshots, previous) when is_map(previous) do
    Enum.flat_map(snapshots, fn snapshot ->
      case Map.fetch(previous, snapshot.key) do
        :error -> [{:added, snapshot}]
        {:ok, hash} when hash != snapshot.hash -> [{:updated, snapshot}]
        {:ok, _unchanged} -> []
      end
    end)
  end

  defp headers(values, params) do
    values
    |> Enum.at(params.header_row - 1, [])
    |> Enum.with_index(1)
    |> Enum.map(fn
      {header, index} when header in [nil, ""] -> "column_#{index}"
      {header, _index} -> to_string(header)
    end)
  end

  # Cells beyond the header row's width keep positional names so no data is
  # silently dropped from the event payload.
  defp zip_headers(headers, raw) do
    raw
    |> Enum.with_index(1)
    |> Map.new(fn {cell, index} ->
      {Enum.at(headers, index - 1) || "column_#{index}", cell}
    end)
  end

  defp row_key(values_map, row_number, params) do
    with column when is_binary(column) <- params[:primary_key_column],
         value when value not in [nil, ""] <- Map.get(values_map, column) do
      "pk:#{value}"
    else
      _missing -> "row:#{row_number}"
    end
  end

  defp row_hash(raw) do
    :sha256
    |> :crypto.hash(Jason.encode!(raw))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_length)
  end
end
