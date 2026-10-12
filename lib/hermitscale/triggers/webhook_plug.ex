defmodule Hermitscale.Triggers.WebhookPlug do
  @moduledoc "Raw-body provider webhook ingress at /hooks/:token, before Phoenix's general parsers."
  @behaviour Plug
  import Plug.Conn
  alias Hermitscale.Triggers.Webhooks
  @max_body 1_048_576

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["hooks", token], method: "POST"} = conn, _opts) do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <-
           content_type
           |> String.split(";", parts: 2)
           |> hd()
           |> String.trim()
           |> String.downcase() == "application/json",
         {:ok, raw, conn} <-
           read_body(conn, length: @max_body, read_length: @max_body, read_timeout: 5_000),
         {:ok, body} when is_map(body) <- Jason.decode(raw),
         {:ok, headers} <- unique_headers(conn.req_headers) do
      conn = fetch_query_params(conn)

      request = %{
        method: conn.method,
        path: conn.path_info,
        headers: headers,
        query: conn.query_params,
        body: body,
        raw_body: raw
      }

      case Webhooks.accept(token, request) do
        {:reply, status, body} -> reply(conn, status, body)
        {:error, :unauthorized} -> reply(conn, 401, %{"error" => "unauthorized"})
        {:error, :not_found} -> reply(conn, 404, %{"error" => "not_found"})
        {:error, :unavailable} -> reply(conn, 503, %{"error" => "unavailable"})
      end
    else
      {:more, _body, conn} -> reply(conn, 413, %{"error" => "payload_too_large"})
      {:error, :duplicate_header} -> reply(conn, 400, %{"error" => "invalid_headers"})
      {:error, _reason} -> reply(conn, 400, %{"error" => "invalid_payload"})
      {:ok, _body} -> reply(conn, 400, %{"error" => "invalid_payload"})
      false -> reply(conn, 415, %{"error" => "unsupported_media_type"})
      _headers -> reply(conn, 415, %{"error" => "unsupported_media_type"})
    end
  end

  def call(%Plug.Conn{path_info: ["hooks", _token]} = conn, _opts),
    do: reply(conn, 405, %{"error" => "method_not_allowed"})

  def call(conn, _opts), do: conn

  defp unique_headers(headers) do
    Enum.reduce_while(headers, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case Map.has_key?(acc, name) and
             name in ~w(content-type x-hub-signature-256 x-github-event x-github-delivery linear-signature linear-delivery) do
        true -> {:halt, {:error, :duplicate_header}}
        false -> {:cont, {:ok, Map.put(acc, name, value)}}
      end
    end)
  end

  defp reply(conn, status, body),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
      |> halt()
end
