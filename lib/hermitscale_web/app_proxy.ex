defmodule HermitscaleWeb.AppProxy do
  @moduledoc """
  Serves `<slug>.<apps domain>` on `HermitscaleWeb.AppsEndpoint` by forwarding
  requests, including WebSocket upgrades, to the app's private Sprite URL.

  Public apps pass through. Org apps need a host-only session cookie, obtained by
  signing in through `HermitscaleWeb.AppAuthController` and the handoff at
  `/_hermitscale/session`. Other hosts get a 404.
  """

  @behaviour Plug

  use HermitscaleWeb, :verified_routes

  import Plug.Conn

  alias Hermitscale.Apps
  alias Hermitscale.Apps.App
  alias Hermitscale.Auth
  alias Hermitscale.Workspaces.SpritesClient
  alias HermitscaleWeb.AppProxy.WebSocket

  @session_cookie "_hs_app"
  @nonce_cookie "_hs_app_nonce"
  @max_ages %{login: 600, handoff: 60, session: 12 * 60 * 60}
  @max_body_bytes 25_000_000
  @methods %{
    "GET" => :get,
    "HEAD" => :head,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete,
    "OPTIONS" => :options
  }
  @hop_by_hop ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade)
  @websocket_handshake ~w(sec-websocket-key sec-websocket-version sec-websocket-extensions)
  @dropped_request_headers ["host", "authorization", "content-length"] ++
                             @hop_by_hop ++ @websocket_handshake

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    app =
      case app_slug(conn.host, Apps.domain()) do
        nil -> nil
        slug -> Apps.get_app_by_slug(slug)
      end

    conn |> serve(app) |> halt()
  end

  @doc false
  def sign_token(kind, data) when is_map_key(@max_ages, kind),
    do: Phoenix.Token.encrypt(HermitscaleWeb.Endpoint, "app #{kind}", data)

  @doc false
  def verify_token(kind, token) when is_map_key(@max_ages, kind),
    do:
      Phoenix.Token.decrypt(HermitscaleWeb.Endpoint, "app #{kind}", token,
        max_age: @max_ages[kind]
      )

  defp app_slug(_host, nil), do: nil

  defp app_slug(host, domain) do
    case String.ends_with?(host, "." <> domain) do
      true -> String.replace_suffix(host, "." <> domain, "")
      false -> nil
    end
  end

  defp serve(conn, nil), do: send_resp(conn, 404, "Not found")

  defp serve(%{path_info: ["_hermitscale", "session"]} = conn, app), do: finish_sign_in(conn, app)
  defp serve(conn, %App{access: :public} = app), do: forward(conn, app, nil)

  defp serve(conn, %App{access: :org, id: app_id} = app) do
    conn = fetch_cookies(conn)

    case verify_token(:session, conn.cookies[@session_cookie]) do
      {:ok, %{app_id: ^app_id, user: user}} -> forward(conn, app, user)
      _missing_or_invalid -> start_sign_in(conn, app)
    end
  end

  defp start_sign_in(%{method: method} = conn, app) when method in ["GET", "HEAD"] do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    state = sign_token(:login, %{app_id: app.id, nonce: nonce, return_to: return_to(conn)})
    {:ok, url} = Auth.authorization_url(state, redirect_uri: url(~p"/apps/auth/callback"))

    conn
    |> put_resp_cookie(@nonce_cookie, nonce, cookie_options(conn, @max_ages.login))
    |> redirect(url)
  end

  defp start_sign_in(conn, _app), do: send_resp(conn, 401, "Sign-in required")

  defp finish_sign_in(conn, %App{id: app_id}) do
    conn = conn |> fetch_cookies() |> fetch_query_params()
    nonce = conn.cookies[@nonce_cookie]

    case verify_token(:handoff, conn.query_params["token"]) do
      {:ok, %{app_id: ^app_id, nonce: ^nonce, user: user, return_to: return_to}}
      when is_binary(nonce) ->
        session = sign_token(:session, %{app_id: app_id, user: user})

        conn
        |> delete_resp_cookie(@nonce_cookie, cookie_options(conn, 0))
        |> put_resp_cookie(@session_cookie, session, cookie_options(conn, @max_ages.session))
        |> redirect(return_to)

      _invalid ->
        send_resp(conn, 403, "Sign-in failed")
    end
  end

  defp forward(conn, app, user) do
    case WebSockAdapter.UpgradeValidation.validate_upgrade(conn) do
      :ok -> forward_websocket(conn, app, user)
      {:error, _not_an_upgrade} -> forward_http(conn, app, user)
    end
  end

  defp forward_websocket(conn, app, user) do
    with :ok <- check_origin(conn, user),
         {:ok, upstream} <-
           SpritesClient.url_websocket(upstream_url(app, conn), request_headers(conn, user)) do
      conn
      |> put_upstream_protocol(upstream.headers)
      |> WebSockAdapter.upgrade(WebSocket, upstream, timeout: :infinity)
    else
      :cross_origin ->
        send_resp(conn, 403, "Cross-origin WebSocket rejected")

      {:error, %Mint.WebSocket.UpgradeFailureError{status_code: status}}
      when status in 400..499 ->
        send_resp(conn, status, "WebSocket upgrade rejected")

      {:error, _reason} ->
        send_resp(conn, 502, "App unavailable")
    end
  end

  # Org apps authenticate with a cookie, so only their own pages may open sockets.
  defp check_origin(_conn, nil), do: :ok

  defp check_origin(conn, _user) do
    case get_req_header(conn, "origin") do
      [] -> :ok
      [origin | _] -> if URI.parse(origin).host == conn.host, do: :ok, else: :cross_origin
    end
  end

  defp put_upstream_protocol(conn, headers) do
    case List.keyfind(headers, "sec-websocket-protocol", 0) do
      {name, protocol} -> put_resp_header(conn, name, protocol)
      nil -> conn
    end
  end

  defp forward_http(conn, app, user) do
    with {:ok, method} <- Map.fetch(@methods, conn.method),
         {:ok, body, conn} <- read_body(conn, length: @max_body_bytes),
         {:ok, response} <-
           SpritesClient.url_request(upstream_url(app, conn),
             method: method,
             headers: request_headers(conn, user),
             body: body
           ) do
      send_response(conn, response)
    else
      :error -> send_resp(conn, 405, "Method not allowed")
      {:more, _partial, conn} -> send_resp(conn, 413, "Request body too large")
      {:error, _reason} -> send_resp(conn, 502, "App unavailable")
    end
  end

  defp upstream_url(app, conn) do
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    String.trim_trailing(app.sprite_url, "/") <> conn.request_path <> query
  end

  defp request_headers(conn, user) do
    forwarded =
      for {name, value} <- conn.req_headers,
          name not in @dropped_request_headers,
          not String.starts_with?(name, ["x-hermitscale-", "x-forwarded-"]),
          header <- strip_app_cookies(name, value),
          do: header

    forwarded ++
      [
        {"x-forwarded-host", conn.host},
        {"x-forwarded-proto", Atom.to_string(conn.scheme)},
        {"x-forwarded-for", conn.remote_ip |> :inet.ntoa() |> to_string()}
      ] ++ identity_headers(user)
  end

  defp strip_app_cookies("cookie", value) do
    value
    |> String.split(";")
    |> Enum.reject(
      &String.starts_with?(String.trim(&1), [@session_cookie <> "=", @nonce_cookie <> "="])
    )
    |> Enum.join(";")
    |> case do
      "" -> []
      cookies -> [{"cookie", cookies}]
    end
  end

  defp strip_app_cookies(name, value), do: [{name, value}]

  defp identity_headers(nil), do: []

  defp identity_headers(user),
    do: [{"x-hermitscale-user-id", user.id}, {"x-hermitscale-user-email", user.email || ""}]

  defp send_response(conn, %Req.Response{status: status} = response)
       when status in [204, 304] or conn.method == "HEAD" do
    Req.cancel_async_response(response)
    conn |> put_upstream_headers(response) |> send_resp(status, "")
  end

  defp send_response(conn, %Req.Response{status: status, body: body} = response) do
    conn = conn |> put_upstream_headers(response) |> send_chunked(status)

    Enum.reduce_while(body, conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, _closed} -> {:halt, conn}
      end
    end)
  end

  defp put_upstream_headers(conn, response) do
    headers =
      for {name, values} <- response.headers,
          name not in ["content-length" | @hop_by_hop],
          value <- values,
          do: {name, value}

    %{conn | resp_headers: headers}
  end

  defp return_to(conn) do
    path = Regex.replace(~r{^[/\\]+}, conn.request_path, "/")
    if conn.query_string == "", do: path, else: path <> "?" <> conn.query_string
  end

  defp redirect(conn, location) do
    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
  end

  defp cookie_options(conn, max_age),
    do: [max_age: max_age, http_only: true, same_site: "Lax", secure: conn.scheme == :https]
end
