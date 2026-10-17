defmodule HermitscaleWeb.AppProxyTest.UpstreamPlug do
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    state = %{
      test_pid: Keyword.fetch!(opts, :test_pid),
      path: conn.request_path,
      headers: Map.new(conn.req_headers)
    }

    conn =
      case Plug.Conn.get_req_header(conn, "sec-websocket-protocol") do
        [protocols | _] ->
          [first | _] = String.split(protocols, ",", trim: true)
          Plug.Conn.put_resp_header(conn, "sec-websocket-protocol", String.trim(first))

        [] ->
          conn
      end

    conn
    |> WebSockAdapter.upgrade(HermitscaleWeb.AppProxyTest.UpstreamSocket, state, [])
    |> Plug.Conn.halt()
  end
end
