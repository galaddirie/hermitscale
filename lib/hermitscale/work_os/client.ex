defmodule Hermitscale.WorkOS.Client do
  @moduledoc """
  Small, typed `Req` adapter for the WorkOS AuthKit and Pipes APIs.

  Redirect policy, tenant authorization, and workflow lookup deliberately remain in their owning contexts.
  """

  @default_base_url "https://api.workos.com"

  @doc """
  Builds the Hosted AuthKit authorization URL.
  """
  def authorization_url(state, opts \\ []) when is_binary(state) do
    config = config()

    params =
      %{
        "client_id" => Keyword.get(opts, :client_id, config[:client_id]),
        "provider" => "authkit",
        "redirect_uri" => Keyword.get(opts, :redirect_uri, config[:redirect_uri]),
        "response_type" => "code",
        "state" => state
      }
      |> maybe_put("max_age", Keyword.get(opts, :max_age))
      |> maybe_put("screen_hint", Keyword.get(opts, :screen_hint))

    {:ok, api_url("/user_management/authorize", config) <> "?" <> URI.encode_query(params)}
  end

  @doc """
  Exchanges an AuthKit authorization code for a WorkOS session.
  """
  def authenticate_with_code(code, request_metadata \\ %{}) when is_binary(code) do
    config = config()

    body =
      %{
        "client_id" => config[:client_id],
        "client_secret" => config[:api_key],
        "grant_type" => "authorization_code",
        "code" => code
      }
      |> put_request_metadata(request_metadata)

    request(:authenticate_code, :post, "/user_management/authenticate", json: body)
  end

  @doc """
  Rotates a WorkOS refresh token, optionally changing organization context.
  """
  def authenticate_with_refresh_token(refresh_token, organization_id, request_metadata \\ %{})
      when is_binary(refresh_token) do
    config = config()

    body =
      %{
        "client_id" => config[:client_id],
        "client_secret" => config[:api_key],
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token
      }
      |> maybe_put("organization_id", organization_id)
      |> put_request_metadata(request_metadata)

    request(:refresh_session, :post, "/user_management/authenticate", json: body)
  end

  @doc """
  Fetches the application's WorkOS signing JWKS.
  """
  def jwks(client_id \\ nil) do
    client_id = client_id || config()[:client_id]
    request(:jwks, :get, "/sso/jwks/#{path_segment(client_id)}", authenticated?: false)
  end

  @doc """
  Vends a short-lived OAuth access token for an immediate provider request.
  """
  def fetch_oauth_token(provider_slug, workos_user_id, workos_organization_id)
      when is_binary(provider_slug) and is_binary(workos_user_id) do
    body =
      %{"user_id" => workos_user_id}
      |> maybe_put("organization_id", workos_organization_id)

    with {:ok, body} <-
           request(
             :fetch_oauth_token,
             :post,
             "/data-integrations/#{path_segment(provider_slug)}/token",
             json: body
           ) do
      normalize_oauth_token(body)
    end
  end

  @doc """
  Revokes one WorkOS AuthKit session.
  """
  def revoke_session(workos_session_id) when is_binary(workos_session_id) do
    request(:revoke_session, :post, "/user_management/sessions/revoke",
      json: %{"session_id" => workos_session_id}
    )
  end

  @doc """
  Builds the browser logout URL for a verified WorkOS session ID.
  """
  def logout_url(workos_session_id, return_to \\ nil) when is_binary(workos_session_id) do
    params =
      %{"session_id" => workos_session_id}
      |> maybe_put("return_to", return_to)

    api_url("/user_management/sessions/logout", config()) <> "?" <> URI.encode_query(params)
  end

  defp request(operation, method, path, opts) do
    config = config()
    authenticated? = Keyword.get(opts, :authenticated?, true)

    request_opts =
      [
        method: method,
        url: api_url(path, config),
        retry: retry_strategy(method),
        max_retries: config[:max_retries] || 2,
        retry_log_level: false,
        receive_timeout: config[:receive_timeout] || 10_000
      ]
      |> maybe_add_auth(authenticated?, config[:api_key])
      |> Keyword.merge(Keyword.drop(opts, [:authenticated?]))
      |> Keyword.merge(config[:req_options] || [])

    :telemetry.span(
      [:hermitscale, :workos, :request],
      %{operation: operation},
      fn ->
        result =
          request_opts
          |> Req.request()
          |> normalize_response()

        {result, %{operation: operation, result: result_class(result)}}
      end
    )
  end

  defp normalize_response({:ok, %Req.Response{status: 204}}), do: {:ok, %{}}

  defp normalize_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299,
       do: {:ok, body}

  defp normalize_response({:ok, %Req.Response{status: 400, body: body}}) do
    case error_code(body) do
      code when code in ["invalid_grant", "invalid_refresh_token", "session_expired"] ->
        {:error, :invalid_grant}

      _code ->
        {:error, {:invalid_request, 400}}
    end
  end

  defp normalize_response({:ok, %Req.Response{status: 401}}), do: {:error, :unauthorized}
  defp normalize_response({:ok, %Req.Response{status: 404}}), do: {:error, :not_found}
  defp normalize_response({:ok, %Req.Response{status: 409}}), do: {:error, :conflict}
  defp normalize_response({:ok, %Req.Response{status: 422}}), do: {:error, :unprocessable}
  defp normalize_response({:ok, %Req.Response{status: 429}}), do: {:error, :rate_limited}

  defp normalize_response({:ok, %Req.Response{status: status}}) when status >= 500,
    do: {:error, :unavailable}

  defp normalize_response({:ok, %Req.Response{status: status}}),
    do: {:error, {:unexpected_status, status}}

  defp normalize_response({:error, _reason}), do: {:error, :unavailable}

  defp normalize_oauth_token(%{"active" => false, "error" => "not_installed"}),
    do: {:error, :not_installed}

  defp normalize_oauth_token(%{"active" => false, "error" => "needs_reauthorization"}),
    do: {:error, :needs_reauthorization}

  defp normalize_oauth_token(%{
         "active" => true,
         "access_token" =>
           %{
             "access_token" => access_token,
             "scopes" => scopes,
             "missing_scopes" => missing_scopes
           } = token
       })
       when is_binary(access_token) and is_list(scopes) and is_list(missing_scopes) do
    {:ok,
     %{
       access_token: access_token,
       expires_at: parse_optional_datetime(token["expires_at"]),
       scopes: scopes,
       missing_scopes: missing_scopes
     }}
  end

  defp normalize_oauth_token(_body), do: {:error, :invalid_token_response}

  defp parse_optional_datetime(nil), do: nil

  defp parse_optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      {:error, _reason} -> nil
    end
  end

  defp put_request_metadata(body, metadata) do
    body
    |> maybe_put("ip_address", Map.get(metadata, :ip_address))
    |> maybe_put("user_agent", Map.get(metadata, :user_agent))
  end

  defp error_code(body) when is_map(body) do
    case body do
      %{"code" => code} when is_binary(code) -> code
      %{"error" => error} when is_binary(error) -> error
      %{"error" => %{"code" => code}} when is_binary(code) -> code
      _other -> nil
    end
  end

  defp error_code(_body), do: nil

  defp result_class({:ok, _body}), do: :ok
  defp result_class({:error, reason}), do: reason

  defp maybe_add_auth(opts, true, api_key) when is_binary(api_key),
    do: Keyword.put(opts, :auth, {:bearer, api_key})

  defp maybe_add_auth(opts, _authenticated?, _api_key), do: opts

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp retry_strategy(method) when method in [:get, :head], do: :safe_transient
  defp retry_strategy(_method), do: false

  defp api_url(path, config) do
    String.trim_trailing(config[:base_url] || @default_base_url, "/") <> path
  end

  defp path_segment(value) when is_binary(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  defp config do
    Application.get_env(:hermitscale, __MODULE__, [])
  end
end
