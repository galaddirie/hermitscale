defmodule HermitscaleWeb.CacheBodyReader do
  @moduledoc """
  `Plug.Parsers` body reader that retains the raw request body for webhook
  routes, where HMAC signature verification needs the exact bytes the sender
  signed. Other routes read the body normally, without the copy.
  """

  def read_body(%Plug.Conn{path_info: ["hooks" | _rest]} = conn, opts) do
    with {:ok, body, conn} <- Plug.Conn.read_body(conn, opts) do
      chunks = [body | conn.assigns[:raw_body_chunks] || []]
      {:ok, body, Plug.Conn.assign(conn, :raw_body_chunks, chunks)}
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  @doc """
  The accumulated raw body for the current request (empty if none was cached).
  """
  def raw_body(%Plug.Conn{} = conn) do
    conn.assigns
    |> Map.get(:raw_body_chunks, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end
end
