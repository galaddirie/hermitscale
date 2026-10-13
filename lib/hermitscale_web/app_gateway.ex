defmodule HermitscaleWeb.AppGateway do
  @moduledoc "Authenticated HTTP access to private native Sprite services on separate app origins."
  import Plug.Conn
  alias Hermitscale.{Apps, Authorization, Workspaces}
  alias Hermitscale.Integrations.ExecutionContext
  alias HermitscaleWeb.Endpoint
  @cookie "__Host-hs_app_access"
  @salt "private-app"
  @ttl 3600
  @body_limit 1_048_576
  @headers ~w(accept accept-language content-type if-none-match if-modified-since range x-requested-with)

  def init(opts), do: opts

  def open_url(scope, app_id) do
    with {:ok, _workspace} <- Apps.workspace(scope, app_id),
         {:ok, host} <- gateway_host() do
      token =
        Phoenix.Token.sign(Endpoint, @salt, %{
          "app_id" => app_id,
          "actor_user_id" => scope.user.id,
          "organization_id" => scope.organization.id
        })

      {:ok, "https://" <> app_id <> "." <> host <> "/gateway/" <> token}
    end
  end

  def call(conn, _opts) do
    case gateway_host() do
      {:ok, host} ->
        if String.ends_with?(conn.host, "." <> host),
          do: conn |> serve(host) |> halt(),
          else: conn

      {:error, :gateway_not_configured} ->
        conn
    end
  end

  defp serve(conn, host) do
    bootstrap = match?(%{method: "GET", path_info: ["gateway", _token]}, conn)

    token =
      if bootstrap, do: List.last(conn.path_info), else: fetch_cookies(conn).cookies[@cookie]

    with {:ok, %{"app_id" => app_id, "organization_id" => org, "actor_user_id" => actor}} <-
           Phoenix.Token.verify(Endpoint, @salt, token, max_age: @ttl),
         true <- conn.host == app_id <> "." <> host,
         {:ok, scope} <-
           Authorization.execution_scope(%ExecutionContext{
             organization_id: org,
             actor_user_id: actor,
             required_permissions: ["apps:read"]
           }),
         {:ok, workspace} <- Apps.workspace(scope, app_id) do
      if bootstrap do
        conn
        |> put_resp_cookie(@cookie, token,
          http_only: true,
          secure: true,
          same_site: "Lax",
          path: "/",
          max_age: @ttl
        )
        |> put_resp_header("referrer-policy", "no-referrer")
        |> put_resp_header("location", "/")
        |> send_resp(302, "")
      else
        proxy(conn, scope, workspace)
      end
    else
      _unavailable -> send_resp(conn, 404, "App access is unavailable or expired")
    end
  end

  defp proxy(conn, scope, workspace) do
    path =
      conn.request_path <> if(conn.query_string == "", do: "", else: "?" <> conn.query_string)

    with {:ok, method} <- method(conn.method),
         {:ok, body, conn} <- read_body(conn, length: @body_limit, read_length: @body_limit),
         {:ok, response} <-
           Workspaces.app_request(scope, workspace.id, path,
             method: method,
             body: body,
             headers: request_headers(conn)
           ),
         true <- is_binary(response.body) and byte_size(response.body) <= @body_limit do
      conn
      |> response_headers(response.headers)
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(response.status, response.body)
    else
      {:more, _body, conn} -> send_resp(conn, 413, "Request exceeds the app upload limit")
      _unavailable -> send_resp(conn, 502, "App request unavailable")
    end
  end

  defp request_headers(conn) do
    headers = Enum.filter(conn.req_headers, fn {name, _value} -> name in @headers end)

    cookies =
      get_req_header(conn, "cookie")
      |> Enum.flat_map(&String.split(&1, ";"))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(
        &String.starts_with?(&1, [@cookie <> "=", "_hermitscale_key=", "request_logger="])
      )

    if cookies == [], do: headers, else: [{"cookie", Enum.join(cookies, "; ")} | headers]
  end

  defp response_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, values}, conn ->
      case String.downcase(name) do
        "set-cookie" ->
          Enum.reduce(List.wrap(values), conn, fn value, conn ->
            cookie =
              value
              |> String.split(";")
              |> Enum.reject(&Regex.match?(~r/^\s*domain\s*=/i, &1))
              |> Enum.join(";")

            prepend_resp_headers(conn, [{"set-cookie", cookie}])
          end)

        allowed
        when allowed in ~w(content-type location etag last-modified content-range accept-ranges) ->
          put_resp_header(conn, allowed, Enum.join(List.wrap(values), ", "))

        _other ->
          conn
      end
    end)
  end

  defp gateway_host do
    config = Application.get_env(:hermitscale, __MODULE__, [])
    host = Keyword.get(config, :host)
    ui_host = URI.parse(Endpoint.url()).host

    if is_binary(host) and host != "" and
         host |> String.split(".") |> Enum.take(-2) !=
           ui_host |> String.split(".") |> Enum.take(-2),
       do: {:ok, String.downcase(host)},
       else: {:error, :gateway_not_configured}
  end

  defp method(method) do
    case method do
      "GET" -> {:ok, :get}
      "POST" -> {:ok, :post}
      "PUT" -> {:ok, :put}
      "PATCH" -> {:ok, :patch}
      "DELETE" -> {:ok, :delete}
      "HEAD" -> {:ok, :head}
      "OPTIONS" -> {:ok, :options}
      _unsupported -> {:error, :unsupported_method}
    end
  end
end
