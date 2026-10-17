defmodule HermitscaleWeb.CredentialBroker do
  @moduledoc """
  The credential broker's HTTP surface, mounted before `Plug.Parsers` so
  request bodies reach providers byte for byte.

    * `/broker/v1/api/<provider>/<path>` forwards to the provider's API host.
    * `/broker/v1/git/<provider>/<owner>/<repo>.git/...` proxies Git smart HTTP
      to the provider's Git host. Fetches are checked as `FETCH /<owner>/<repo>`
      and pushes as `PUSH /<owner>/<repo>`.

  Callers authenticate with a broker token as a bearer token or as a Basic
  password, which lets Git credential helpers supply it. Provider credentials
  are attached upstream and never returned. See `Hermitscale.CredentialBroker`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Hermitscale.CredentialBroker

  @methods %{
    "GET" => :get,
    "HEAD" => :head,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete
  }
  @max_api_body 10_000_000
  @max_git_body 100_000_000
  @hop_by_hop ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade)
  @dropped_request_headers ~w(host authorization cookie content-length forwarded via x-real-ip) ++
                             @hop_by_hop
  @credential_errors [
    :not_granted,
    :endpoint_not_allowed,
    :execution_actor_ineligible,
    :needs_reauthorization,
    :account_not_found,
    :insufficient_scopes,
    :unsupported_auth_method,
    :not_installed,
    :account_selection_required,
    :multiple_connections_unavailable
  ]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["broker", "v1" | route]} = conn, _opts),
    do: conn |> serve(route) |> halt()

  def call(conn, _opts), do: conn

  defp serve(conn, ["api", provider | [_ | _] = segments]) do
    with {:ok, method} <- Map.fetch(@methods, conn.method) |> or_error(:method_not_allowed),
         {:ok, segments, path} <- decode_segments(segments),
         {:ok, access} <- CredentialBroker.authorize(token(conn), provider, conn.method, path),
         {:ok, body, conn} <- read_body(conn, length: @max_api_body, read_length: 1_000_000),
         {:ok, response} <-
           CredentialBroker.request(
             access,
             method,
             segments,
             conn.query_string,
             request_headers(conn, ["accept-encoding", "content-encoding"]),
             body
           ) do
      audit(access, conn.method, path, response.status)

      conn
      |> put_upstream_headers(response, ["content-encoding"])
      |> send_resp(response.status, response.body)
    else
      error -> fail(conn, error)
    end
  end

  defp serve(conn, ["git", provider, owner, repo | rest]) do
    conn = fetch_query_params(conn)

    with {:ok, method, operation} <- git_operation(conn.method, rest, conn.query_params),
         {:ok, [owner, repo], _path} <- decode_segments([owner, repo]),
         path = "/" <> owner <> "/" <> String.replace_suffix(repo, ".git", ""),
         {:ok, access} <- CredentialBroker.authorize(token(conn), provider, operation, path),
         {:ok, body, conn} <- read_body(conn, length: @max_git_body, read_length: 1_000_000),
         {:ok, response} <-
           CredentialBroker.git_request(
             access,
             method,
             [owner, repo | rest],
             conn.query_string,
             request_headers(conn, []),
             body
           ) do
      audit(access, operation, path, response.status)
      stream_response(conn, response)
    else
      error -> fail(conn, error)
    end
  end

  defp serve(conn, _route), do: error(conn, 404, "not_found")

  defp git_operation("GET", ["info", "refs"], %{"service" => "git-upload-pack"}),
    do: {:ok, :get, "FETCH"}

  defp git_operation("GET", ["info", "refs"], %{"service" => "git-receive-pack"}),
    do: {:ok, :get, "PUSH"}

  defp git_operation("POST", ["git-upload-pack"], _params), do: {:ok, :post, "FETCH"}
  defp git_operation("POST", ["git-receive-pack"], _params), do: {:ok, :post, "PUSH"}
  defp git_operation(_method, _rest, _params), do: {:error, :not_found}

  # Rules match the decoded path, and segments are re-encoded upstream, so a
  # segment that could change meaning there, such as an encoded slash or a dot
  # segment, is rejected.
  defp decode_segments(segments) do
    decoded = Enum.map(segments, &URI.decode/1)

    case Enum.all?(decoded, &(&1 not in [".", ".."] and not String.contains?(&1, "/"))) do
      true -> {:ok, decoded, "/" <> Enum.join(decoded, "/")}
      false -> {:error, :invalid_path}
    end
  rescue
    ArgumentError -> {:error, :invalid_path}
  end

  defp token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      ["Basic " <> encoded] -> basic_password(encoded)
      _missing -> nil
    end
  end

  defp basic_password(encoded) do
    case Base.decode64(encoded) do
      {:ok, credentials} -> credentials |> String.split(":", parts: 2) |> List.last()
      :error -> nil
    end
  end

  defp request_headers(conn, dropped) do
    for {name, value} <- conn.req_headers,
        name not in @dropped_request_headers,
        name not in dropped,
        not String.starts_with?(name, ["x-forwarded-", "x-hermitscale-"]),
        do: {name, value}
  end

  defp put_upstream_headers(conn, response, dropped) do
    headers =
      for {name, values} <- response.headers,
          name not in ["content-length", "set-cookie" | @hop_by_hop],
          name not in dropped,
          value <- values,
          do: {name, value}

    %{conn | resp_headers: headers}
  end

  defp stream_response(conn, %Req.Response{status: status} = response)
       when status in [204, 304] or conn.method == "HEAD" do
    Req.cancel_async_response(response)
    conn |> put_upstream_headers(response, []) |> send_resp(status, "")
  end

  defp stream_response(conn, %Req.Response{status: status, body: body} = response) do
    conn = conn |> put_upstream_headers(response, []) |> send_chunked(status)

    Enum.reduce_while(body, conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, _closed} -> {:halt, conn}
      end
    end)
  end

  defp audit(access, method, path, status) do
    :telemetry.execute(
      [:hermitscale, :credential_broker, :request],
      %{status: status},
      %{
        workspace_id: access.grant.workspace_id,
        org_id: access.grant.org_id,
        grant_id: access.grant.id,
        token_id: access.token.id,
        actor_user_id: access.token.actor_user_id,
        provider: access.grant.provider,
        method: method,
        path: path
      }
    )
  end

  defp fail(_conn, {:more, _partial, conn}), do: error(conn, 413, "request_too_large")

  defp fail(conn, {:error, :unauthorized}) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="Hermitscale broker"))
    |> error(401, "unauthorized")
  end

  defp fail(conn, {:error, reason}) when reason in @credential_errors,
    do: error(conn, 403, Atom.to_string(reason))

  defp fail(conn, {:error, reason})
       when reason in [:not_found, :unknown_provider, :git_unsupported],
       do: error(conn, 404, "not_found")

  defp fail(conn, {:error, :method_not_allowed}), do: error(conn, 405, "method_not_allowed")
  defp fail(conn, {:error, :invalid_path}), do: error(conn, 400, "invalid_path")

  defp fail(conn, {:error, reason}) when reason in [:unavailable, :rate_limited],
    do: error(conn, 503, "unavailable")

  defp fail(conn, {:error, _reason}), do: error(conn, 502, "provider_unavailable")

  defp error(conn, status, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => code}))
  end

  defp or_error({:ok, _value} = ok, _reason), do: ok
  defp or_error(:error, reason), do: {:error, reason}
end
