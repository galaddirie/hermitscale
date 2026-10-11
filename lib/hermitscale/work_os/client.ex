defmodule Hermitscale.WorkOS.Client do
  @moduledoc """
  Small, typed `Req` adapter for the WorkOS AuthKit, Events, and Pipes APIs.

  Local transactions, redirect policy, tenant authorization, and workflow
  lookup deliberately remain in their owning contexts.
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
  Lists one ordered page from the WorkOS Events API.
  """
  def list_events(after_cursor, event_types, opts \\ []) when is_list(event_types) do
    params =
      after_cursor
      |> pagination_params(opts)
      |> Map.put("events", Enum.join(event_types, ","))
      |> maybe_put("range_start", encode_datetime(Keyword.get(opts, :range_start)))
      |> maybe_put("range_end", encode_datetime(Keyword.get(opts, :range_end)))

    request(:list_events, :get, "/events", params: params)
  end

  @doc """
  Lists one page of WorkOS Users for State API reconciliation.
  """
  def list_users(after_cursor \\ nil, opts \\ []) do
    request(:list_users, :get, "/user_management/users",
      params: pagination_params(after_cursor, opts)
    )
  end

  @doc """
  Lists one page of WorkOS Organizations for State API reconciliation.
  """
  def list_organizations(after_cursor \\ nil, opts \\ []) do
    request(:list_organizations, :get, "/organizations",
      params: pagination_params(after_cursor, opts)
    )
  end

  @doc """
  Gets a WorkOS Organization by Hermitscale's stable external ID.
  """
  def get_organization_by_external_id(external_id) when is_binary(external_id) do
    request(
      :get_organization_by_external_id,
      :get,
      "/organizations/external_id/#{path_segment(external_id)}",
      []
    )
  end

  @doc """
  Creates a WorkOS Organization mapped to a stable local organization ID.
  """
  def create_organization(name, external_id)
      when is_binary(name) and is_binary(external_id) do
    request(:create_organization, :post, "/organizations",
      json: %{"name" => name, "external_id" => external_id}
    )
  end

  @doc """
  Lists one page of memberships for a WorkOS Organization.
  """
  def list_organization_memberships(organization_id, after_cursor \\ nil, opts \\ [])
      when is_binary(organization_id) do
    statuses = Keyword.get(opts, :statuses, ["active", "inactive", "pending"])

    params =
      after_cursor
      |> pagination_params(opts)
      |> Map.put("organization_id", organization_id)
      |> maybe_put("statuses", encode_list(statuses))

    request(
      :list_organization_memberships,
      :get,
      "/user_management/organization_memberships",
      params: params
    )
  end

  @doc """
  Creates a WorkOS Organization Membership.
  """
  def create_organization_membership(organization_id, user_id, role_slug)
      when is_binary(organization_id) and is_binary(user_id) and is_binary(role_slug) do
    request(
      :create_organization_membership,
      :post,
      "/user_management/organization_memberships",
      json: %{
        "organization_id" => organization_id,
        "user_id" => user_id,
        "role_slug" => role_slug
      }
    )
  end

  @doc """
  Updates the role assigned to a WorkOS Organization Membership.
  """
  def update_organization_membership(membership_id, role_slug)
      when is_binary(membership_id) and is_binary(role_slug) do
    request(
      :update_organization_membership,
      :put,
      "/user_management/organization_memberships/#{path_segment(membership_id)}",
      json: %{"role_slug" => role_slug}
    )
  end

  @doc """
  Deactivates a WorkOS Organization Membership.
  """
  def deactivate_organization_membership(membership_id) when is_binary(membership_id) do
    request(
      :deactivate_organization_membership,
      :put,
      "/user_management/organization_memberships/#{path_segment(membership_id)}/deactivate",
      json: %{}
    )
  end

  @doc """
  Lists one page of active WorkOS sessions for a user.
  """
  def list_sessions(user_id, after_cursor \\ nil, opts \\ []) when is_binary(user_id) do
    request(
      :list_sessions,
      :get,
      "/user_management/users/#{path_segment(user_id)}/sessions",
      params: pagination_params(after_cursor, opts)
    )
  end

  @doc """
  Lists configured Pipes providers and nested connection state for a user.
  """
  def list_providers(workos_user_id, workos_organization_id \\ nil)
      when is_binary(workos_user_id) do
    params = maybe_put(%{}, "organization_id", workos_organization_id)

    request(
      :list_providers,
      :get,
      "/user_management/users/#{path_segment(workos_user_id)}/data_providers",
      params: params
    )
  end

  @doc """
  Starts the WorkOS Pipes authorization flow for a configured provider.
  """
  def authorize_connection(provider_slug, workos_user_id, workos_organization_id, return_to)
      when is_binary(provider_slug) and is_binary(workos_user_id) and is_binary(return_to) do
    body =
      %{"user_id" => workos_user_id, "return_to" => return_to}
      |> maybe_put("organization_id", workos_organization_id)

    request(
      :authorize_connection,
      :post,
      "/data-integrations/#{path_segment(provider_slug)}/authorize",
      json: body
    )
  end

  @doc """
  Gets one WorkOS Pipes connected account by user/provider tuple.
  """
  def get_connected_account(provider_slug, workos_user_id, workos_organization_id)
      when is_binary(provider_slug) and is_binary(workos_user_id) do
    params = maybe_put(%{}, "organization_id", workos_organization_id)

    request(
      :get_connected_account,
      :get,
      "/user_management/users/#{path_segment(workos_user_id)}/connected_accounts/#{path_segment(provider_slug)}",
      params: params
    )
  end

  @doc """
  Deletes one WorkOS Pipes connected account.
  """
  def delete_connected_account(provider_slug, workos_user_id, workos_organization_id)
      when is_binary(provider_slug) and is_binary(workos_user_id) do
    params = maybe_put(%{}, "organization_id", workos_organization_id)

    request(
      :delete_connected_account,
      :delete,
      "/user_management/users/#{path_segment(workos_user_id)}/connected_accounts/#{path_segment(provider_slug)}",
      params: params
    )
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
  Permanently deletes a WorkOS User.
  """
  def delete_user(workos_user_id) when is_binary(workos_user_id) do
    request(
      :delete_user,
      :delete,
      "/user_management/users/#{path_segment(workos_user_id)}",
      []
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

  defp pagination_params(after_cursor, opts) do
    %{"limit" => Keyword.get(opts, :limit, 100)}
    |> maybe_put("after", after_cursor)
    |> maybe_put("order", Keyword.get(opts, :order))
  end

  defp encode_list(values) when is_list(values), do: Enum.join(values, ",")
  defp encode_list(_values), do: nil

  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(value) when is_binary(value), do: value
  defp encode_datetime(nil), do: nil

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
