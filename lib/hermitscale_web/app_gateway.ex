defmodule HermitscaleWeb.AppGateway do
  @moduledoc "Isolated-origin generated-app HTTP gateway. Upstream destinations and credentials stay server-owned."
  import Plug.Conn
  alias Hermitscale.{Apps, Workspaces}
  @body_limit 1_048_576
  @access_cookie "__Host-hs_app_access"
  @request_headers ~w(accept accept-language content-type if-none-match if-modified-since range x-requested-with sec-websocket-protocol)

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: ["gateway", token | path]} = conn, _opts) do
    conn |> proxy(token, path) |> halt()
  end

  def call(conn, _opts) do
    case generated_host?(conn.host) do
      true ->
        case app_cookie(conn) do
          nil -> conn |> send_resp(404, "App access is unavailable or expired") |> halt()
          token -> conn |> proxy(token, conn.path_info) |> halt()
        end

      false ->
        conn
    end
  end

  def proxy(conn, token, path) do
    with :ok <- isolated_host(conn),
         {:ok, access} <- Apps.resolve_access(token),
         :ok <- selected_origin(conn, access.origin_id),
         {:ok, upstream_path} <- request_path(path, conn.query_string) do
      conn = access_cookie(conn, token, access)

      case {conn.method, conn.path_info, get_req_header(conn, "upgrade")} do
        {"GET", ["gateway", ^token], []} ->
          conn |> put_resp_header("location", "/") |> send_resp(302, "")

        {_method, _path, ["websocket"]} ->
          WebSockAdapter.upgrade(
            conn,
            HermitscaleWeb.AppGatewaySocket,
            %{access: access, token: token, path: upstream_path, headers: request_headers(conn)},
            timeout: 60_000
          )

        _http ->
          with {:ok, body, conn} <- request_body(conn),
               {:ok, response} <-
                 Workspaces.app_request(access.scope, access.workspace_id, upstream_path,
                   method: method(conn.method),
                   headers: request_headers(conn),
                   body: body
                 ),
               {:ok, body} <- response_body(response.body) do
            send_upstream(conn, response, body, token)
          else
            {:error, :body_too_large} ->
              send_resp(conn, 413, "Request exceeds the app upload limit")

            {:error, _reason} ->
              send_resp(conn, 502, "App request unavailable")
          end
      end
    else
      {:error, :gateway_not_configured} ->
        send_resp(conn, 503, "App origin is not configured")

      {:error, :origin_not_isolated} ->
        send_resp(conn, 403, "Generated apps require their isolated origin")

      {:error, :environment_maintenance} ->
        send_resp(conn, 503, "This app is being updated")

      {:error, _reason} ->
        send_resp(conn, 404, "App access is unavailable or expired")
    end
  end

  defp isolated_host(conn) do
    with {:ok, gateway} <- Apps.gateway_host() do
      ui = URI.parse(HermitscaleWeb.Endpoint.url()).host
      actual = String.downcase(conn.host)
      expected = String.downcase(gateway)

      cond do
        actual != expected and not String.ends_with?(actual, "." <> expected) ->
          {:error, :origin_not_isolated}

        registrable(expected) == registrable(ui) ->
          {:error, :origin_not_isolated}

        true ->
          :ok
      end
    end
  end

  # Requiring different final labels also rejects sibling hosts on common multi-label suffixes.
  defp registrable(host), do: host |> String.downcase() |> String.split(".") |> Enum.take(-2)

  defp request_path(path, query) do
    cond do
      Enum.any?(path, &(String.contains?(&1, [<<0>>, "\\"]) or &1 in [".", ".."])) ->
        {:error, :invalid_path}

      byte_size(query) > 8192 ->
        {:error, :invalid_query}

      true ->
        {:ok,
         "/" <>
           Enum.map_join(
             path,
             "/",
             &URI.encode(&1, fn c -> URI.char_unreserved?(c) or c == ?: end)
           ) <> if(query == "", do: "", else: "?" <> query)}
    end
  end

  defp request_headers(conn) do
    headers = Enum.filter(conn.req_headers, fn {name, _value} -> name in @request_headers end)

    cookies =
      get_req_header(conn, "cookie")
      |> Enum.flat_map(&String.split(&1, ";"))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(
        &String.starts_with?(&1, ["_hermitscale_key=", "request_logger=", @access_cookie <> "="])
      )

    case cookies do
      [] -> headers
      values -> [{"cookie", Enum.join(values, "; ")} | headers]
    end
  end

  defp request_body(conn) do
    case read_body(conn, length: @body_limit, read_length: @body_limit, read_timeout: 15_000) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _body, _conn} -> {:error, :body_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp response_body(body) when is_binary(body) and byte_size(body) <= @body_limit,
    do: {:ok, body}

  defp response_body(body) when is_map(body) or is_list(body) do
    response_body(Jason.encode!(body))
  end

  defp response_body(_body), do: {:error, :response_too_large}

  defp send_upstream(conn, response, body, _token) do
    prefix = "/"
    ui_origin = HermitscaleWeb.Endpoint.url()

    csp =
      "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors " <>
        ui_origin <> "; object-src 'none'; base-uri 'self'"

    conn =
      conn
      |> put_resp_header("content-security-policy", csp)
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, no-store")

    conn =
      response.headers
      |> Enum.reduce(conn, fn {key, values}, conn ->
        name = String.downcase(key)
        values = List.wrap(values)

        case name do
          "set-cookie" ->
            Enum.reduce(values, conn, fn value, conn ->
              prepend_resp_headers(conn, [{"set-cookie", isolate_cookie(value, prefix)}])
            end)

          "location" ->
            case values do
              ["/" <> destination | _] ->
                put_resp_header(conn, "location", prefix <> destination)

              [destination | _] ->
                case URI.parse(destination) do
                  %URI{scheme: nil, host: nil} -> put_resp_header(conn, "location", destination)
                  _external -> put_resp_header(conn, "location", prefix)
                end

              [] ->
                conn
            end

          allowed
          when allowed in ~w(content-type etag last-modified content-range accept-ranges x-hermitscale-revision) ->
            put_resp_header(conn, name, Enum.join(values, ", "))

          _stripped ->
            conn
        end
      end)

    send_resp(conn, response.status, body)
  end

  defp access_cookie(conn, token, access) do
    ttl =
      case access.grant do
        nil -> 86_400
        grant -> max(DateTime.diff(grant.expires_at, DateTime.utc_now(), :second), 0)
      end

    put_resp_cookie(conn, @access_cookie, token,
      http_only: true,
      secure: true,
      same_site: "Lax",
      path: "/",
      max_age: ttl
    )
  end

  defp app_cookie(conn) do
    conn
    |> get_req_header("cookie")
    |> Enum.flat_map(&String.split(&1, ";"))
    |> Enum.find_value(fn cookie ->
      case String.split(String.trim(cookie), "=", parts: 2) do
        [@access_cookie, token] -> token
        _other_cookie -> nil
      end
    end)
  end

  defp generated_host?(host) do
    case Apps.gateway_host() do
      {:ok, gateway} ->
        String.downcase(host) == String.downcase(gateway) or
          String.ends_with?(String.downcase(host), "." <> String.downcase(gateway))

      {:error, _not_configured} ->
        false
    end
  end

  defp selected_origin(conn, origin_id) do
    {:ok, gateway} = Apps.gateway_host()

    case String.downcase(conn.host) == String.downcase(origin_id <> "." <> gateway) do
      true -> :ok
      false -> {:error, :origin_not_isolated}
    end
  end

  defp isolate_cookie(cookie, prefix) do
    cookie
    |> String.split(";")
    |> Enum.reject(&Regex.match?(~r/^\s*(?:domain|path)\s*=/i, &1))
    |> Enum.join(";")
    |> Kernel.<>("; Path=" <> prefix <> "; Secure; SameSite=Lax")
  end

  defp method("GET"), do: :get
  defp method("POST"), do: :post
  defp method("PUT"), do: :put
  defp method("PATCH"), do: :patch
  defp method("DELETE"), do: :delete
  defp method("HEAD"), do: :head
  defp method("OPTIONS"), do: :options
end
