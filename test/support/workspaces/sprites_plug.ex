defmodule Hermitscale.WorkspacesTest.SpritesPlug do
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    state = %{
      test_pid: Keyword.fetch!(opts, :test_pid),
      path: conn.request_path,
      query: URI.query_decoder(conn.query_string) |> Enum.to_list(),
      authorization: Plug.Conn.get_req_header(conn, "authorization")
    }

    case List.keyfind(state.query, "cmd", 0) do
      {"cmd", "rejected"} ->
        Plug.Conn.send_resp(conn, 403, "sprites-test-secret")

      _command ->
        conn
        |> WebSockAdapter.upgrade(Hermitscale.WorkspacesTest.SpritesSocket, state,
          timeout: :infinity
        )
        |> Plug.Conn.halt()
    end
  end
end
