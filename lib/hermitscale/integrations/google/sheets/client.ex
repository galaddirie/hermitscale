defmodule Hermitscale.Integrations.Google.Sheets.Client do
  @moduledoc """
  Req-based Google Sheets API client used by catalog nodes.
  """

  @base_url "https://sheets.googleapis.com/v4/spreadsheets"

  alias Hermitscale.Integrations.Request

  @doc """
  Reads values from a spreadsheet range.
  """
  def read_rows(credentials, spreadsheet_id, range, opts \\ []) do
    request(
      :get,
      credentials,
      "/#{path_segment(spreadsheet_id)}/values/#{path_segment(range)}",
      opts
    )
  end

  @doc """
  Appends one row or a list of rows to a spreadsheet range.
  """
  def append_row(credentials, spreadsheet_id, range, values, opts \\ []) do
    request(
      :post,
      credentials,
      "/#{path_segment(spreadsheet_id)}/values/#{path_segment(range)}:append",
      Keyword.merge(
        [
          params: [valueInputOption: "USER_ENTERED"],
          json: %{values: rows(values)}
        ],
        opts
      )
    )
  end

  defp request(method, credentials, path, opts) do
    req_opts =
      Application.get_env(:hermitscale, :google_sheets_req_options, []) |> Keyword.merge(opts)

    case Request.request(method, @base_url <> path, credentials, req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:google_sheets_request_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp path_segment(value) when is_binary(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  defp rows([first | _rest] = rows) when is_list(first), do: rows
  defp rows(row) when is_list(row), do: [row]
end
