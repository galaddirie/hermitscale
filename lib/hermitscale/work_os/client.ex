defmodule Hermitscale.WorkOS.Client do
  @moduledoc """
  Small, typed `Req` adapter for the WorkOS AuthKit and Pipes APIs.

  Redirect policy, tenant authorization, and workflow lookup deliberately remain in their owning contexts.
  """

  @default_base_url "https://api.workos.com"

  @doc "Returns the configured adapter for a context, retaining one WorkOS boundary."
  def adapter(context), do: Application.get_env(:hermitscale, context, [])[:client] || __MODULE__

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

  @doc "Vends credentials for exactly one organization-owned account."
  def vend_credentials(slug, user_id, org_id, account_id) do
    with {:ok, body} <-
           request(
             :vend_credentials,
             :post,
             "/data-integrations/#{path_segment(slug)}/credentials",
             json: %{
               "user_id" => user_id,
               "organization_id" => org_id,
               "connection_owner" => "organization",
               "connected_account_id" => account_id,
               "supports_multiple_connections" => true
             }
           ) do
      normalize_credential(body)
    end
  end

  @doc "Lists organization-owned providers and accounts, including plural account selections."
  def list_org_providers(org_id) do
    request(:list_org_providers, :get, "/organizations/#{path_segment(org_id)}/data_providers",
      params: [supports_multiple_connections: true]
    )
  end

  def authorize_connection(slug, user_id, org_id, return_to, account_id \\ nil) do
    body =
      %{
        "user_id" => user_id,
        "organization_id" => org_id,
        "connection_owner" => "organization",
        "return_to" => return_to,
        "connection_intent" => if(account_id, do: "reauthorize", else: "add")
      }
      |> maybe_put("connected_account_id", account_id)

    request(:authorize_connection, :post, "/data-integrations/#{path_segment(slug)}/authorize",
      json: body
    )
  end

  def rotate_api_key(slug, user_id, org_id, account_id, secret) do
    body =
      %{
        "user_id" => user_id,
        "organization_id" => org_id,
        "connection_owner" => "organization",
        "secret" => secret
      }
      |> maybe_put("connected_account_id", account_id)

    request(:rotate_api_key, :put, "/data-integrations/#{path_segment(slug)}/api-key", json: body)
  end

  def disconnect_account(slug, org_id, account_id) do
    request(
      :disconnect_account,
      :delete,
      "/organizations/#{path_segment(org_id)}/connected_accounts/#{path_segment(slug)}",
      params: [connected_account_id: account_id, supports_multiple_connections: true]
    )
  end

  def get_organization_by_external_id(external_id),
    do:
      request(
        :get_organization_by_external_id,
        :get,
        "/organizations/external_id/#{path_segment(external_id)}",
        []
      )

  def get_organization(org_id),
    do: request(:get_organization, :get, "/organizations/#{path_segment(org_id)}", [])

  def create_organization(attrs),
    do: request(:create_organization, :post, "/organizations", json: attrs)

  def list_memberships(user_id, org_id \\ nil) do
    params = %{} |> maybe_put("user_id", user_id) |> maybe_put("organization_id", org_id)
    list_all(:list_memberships, "/user_management/organization_memberships", params)
  end

  def get_membership(id),
    do:
      request(
        :get_membership,
        :get,
        "/user_management/organization_memberships/#{path_segment(id)}",
        []
      )

  def create_membership(user_id, org_id, role),
    do:
      request(:create_membership, :post, "/user_management/organization_memberships",
        json: %{"user_id" => user_id, "organization_id" => org_id, "role_slug" => role}
      )

  def update_membership(id, role),
    do:
      request(
        :update_membership,
        :put,
        "/user_management/organization_memberships/#{path_segment(id)}",
        json: %{"role_slug" => role}
      )

  def remove_membership(id),
    do:
      request(
        :remove_membership,
        :delete,
        "/user_management/organization_memberships/#{path_segment(id)}",
        []
      )

  def invite_member(org_id, inviter_id, email, role),
    do:
      request(:invite_member, :post, "/user_management/invitations",
        json: %{
          "organization_id" => org_id,
          "inviter_user_id" => inviter_id,
          "email" => email,
          "role_slug" => role
        }
      )

  def get_role(slug),
    do: request(:get_role, :get, "/authorization/roles/#{path_segment(slug)}", [])

  defp list_all(operation, path, params, pages \\ [], seen \\ MapSet.new()) do
    with {:ok, %{"data" => data} = page} <- request(operation, :get, path, params: params),
         {:ok, cursor} <- pagination_cursor(page) do
      pages = [data | pages]

      cond do
        is_nil(cursor) ->
          {:ok, %{"data" => pages |> Enum.reverse() |> List.flatten()}}

        MapSet.member?(seen, cursor) ->
          {:error, :invalid_response}

        true ->
          list_all(
            operation,
            path,
            Map.put(params, "after", cursor),
            pages,
            MapSet.put(seen, cursor)
          )
      end
    end
  end

  defp pagination_cursor(%{"list_metadata" => %{"after" => cursor}})
       when is_nil(cursor) or (is_binary(cursor) and cursor != ""),
       do: {:ok, cursor}

  defp pagination_cursor(%{"list_metadata" => metadata}) when not is_nil(metadata),
    do: {:error, :invalid_response}

  defp pagination_cursor(_page), do: {:ok, nil}

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
        redirect: false,
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
          |> validate_response(operation)

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

      code
      when code in [
             "account_selection_required",
             "connected_account_not_found",
             "insufficient_scopes",
             "multiple_connections_unavailable"
           ] ->
        credential_error(code)

      _code ->
        {:error, {:invalid_request, 400}}
    end
  end

  defp normalize_response({:ok, %Req.Response{status: 403}}), do: {:error, :forbidden}
  defp normalize_response({:ok, %Req.Response{status: 401}}), do: {:error, :unauthorized}
  defp normalize_response({:ok, %Req.Response{status: 404}}), do: {:error, :not_found}
  defp normalize_response({:ok, %Req.Response{status: 409}}), do: {:error, :conflict}

  defp normalize_response({:ok, %Req.Response{status: 422, body: body}}) do
    case error_code(body) do
      code
      when code in [
             "account_selection_required",
             "connected_account_not_found",
             "insufficient_scopes",
             "multiple_connections_unavailable"
           ] ->
        credential_error(code)

      _ ->
        {:error, :unprocessable}
    end
  end

  defp normalize_response({:ok, %Req.Response{status: 429}}), do: {:error, :rate_limited}

  defp normalize_response({:ok, %Req.Response{status: status}}) when status >= 500,
    do: {:error, :unavailable}

  defp normalize_response({:ok, %Req.Response{status: status}}),
    do: {:error, {:unexpected_status, status}}

  defp normalize_response({:error, _reason}), do: {:error, :unavailable}

  defp validate_response({:ok, body}, operation) do
    case valid_response?(operation, body) do
      true -> {:ok, body}
      false -> {:error, :invalid_response}
    end
  end

  defp validate_response({:error, _reason} = error, _operation), do: error

  defp valid_response?(operation, %{
         "access_token" => access,
         "refresh_token" => refresh,
         "user" => %{"id" => id} = user
       })
       when operation in [:authenticate_code, :refresh_session],
       do:
         required_string?(access) and required_string?(refresh) and required_string?(id) and
           Enum.all?(~w(email first_name last_name), &optional_string?(user[&1]))

  defp valid_response?(:jwks, %{"keys" => keys}), do: is_list(keys)

  defp valid_response?(operation, %{"id" => id})
       when operation in [
              :get_organization,
              :get_organization_by_external_id,
              :create_organization
            ],
       do: required_string?(id)

  defp valid_response?(operation, body)
       when operation in [:get_membership, :create_membership, :update_membership],
       do: valid_membership?(body)

  defp valid_response?(:list_memberships, %{"data" => data}) when is_list(data),
    do: Enum.all?(data, &valid_membership?/1)

  defp valid_response?(:get_role, %{"permissions" => permissions}), do: string_list?(permissions)

  defp valid_response?(:list_org_providers, %{"data" => data}) when is_list(data),
    do: Enum.all?(data, &valid_provider?/1)

  defp valid_response?(:authorize_connection, %{"url" => url}), do: required_string?(url)

  defp valid_response?(operation, body)
       when operation in [
              :vend_credentials,
              :rotate_api_key,
              :disconnect_account,
              :remove_membership,
              :invite_member,
              :revoke_session
            ],
       do: is_map(body)

  defp valid_response?(_operation, _body), do: false

  defp valid_membership?(
         %{"id" => id, "user_id" => user, "organization_id" => org, "status" => status} =
           membership
       ) do
    Enum.all?([id, user, org, status], &required_string?/1) and valid_role?(membership["role"])
  end

  defp valid_membership?(_membership), do: false
  defp valid_role?(nil), do: true
  defp valid_role?(%{"slug" => slug}), do: required_string?(slug)
  defp valid_role?(_role), do: false

  defp valid_provider?(%{"slug" => slug, "connected_accounts" => accounts})
       when is_list(accounts),
       do: required_string?(slug) and Enum.all?(accounts, &valid_account?/1)

  defp valid_provider?(%{"slug" => slug, "connected_account" => account}),
    do: required_string?(slug) and (is_nil(account) or valid_account?(account))

  defp valid_provider?(%{"slug" => slug} = provider),
    do: required_string?(slug) and is_nil(provider["connected_accounts"])

  defp valid_provider?(_provider), do: false

  defp valid_account?(%{"id" => id, "state" => state, "auth_method" => method} = account) do
    Enum.all?([id, state, method], &required_string?/1) and
      optional_string?(account["organization_id"]) and optional_string?(account["user_id"]) and
      (is_nil(account["scopes"]) or string_list?(account["scopes"]))
  end

  defp valid_account?(_account), do: false
  defp required_string?(value), do: is_binary(value) and value != ""
  defp optional_string?(nil), do: true
  defp optional_string?(value), do: required_string?(value)
  defp string_list?(values) when is_list(values), do: Enum.all?(values, &is_binary/1)
  defp string_list?(_values), do: false

  defp normalize_credential(%{"active" => false, "error" => code}), do: credential_error(code)

  defp normalize_credential(%{
         "active" => true,
         "credential" => %{"auth_method" => method, "value" => value} = credential
       })
       when method in ["oauth", "api_key"] and is_binary(value) and value != "" do
    with {:ok, scopes} <- optional_scopes(credential["scopes"]),
         {:ok, missing} <- optional_scopes(credential["missing_scopes"]),
         {:ok, expires_at} <- parse_optional_datetime(credential["expires_at"]) do
      {:ok,
       %{
         auth_method: method,
         value: value,
         expires_at: expires_at,
         scopes: scopes,
         missing_scopes: missing
       }}
    end
  end

  defp normalize_credential(_body), do: {:error, :invalid_credential_response}

  defp credential_error("not_installed"), do: {:error, :not_installed}
  defp credential_error("needs_reauthorization"), do: {:error, :needs_reauthorization}
  defp credential_error("account_selection_required"), do: {:error, :account_selection_required}
  defp credential_error("connected_account_not_found"), do: {:error, :account_not_found}
  defp credential_error("insufficient_scopes"), do: {:error, :insufficient_scopes}

  defp credential_error("multiple_connections_unavailable"),
    do: {:error, :multiple_connections_unavailable}

  defp credential_error(_code), do: {:error, :invalid_credential_response}

  defp optional_scopes(nil), do: {:ok, []}

  defp optional_scopes(scopes) do
    case string_list?(scopes) do
      true -> {:ok, scopes}
      false -> {:error, :invalid_credential_response}
    end
  end

  defp parse_optional_datetime(nil), do: {:ok, nil}

  defp parse_optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      {:error, _reason} -> {:error, :invalid_credential_response}
    end
  end

  defp parse_optional_datetime(_value), do: {:error, :invalid_credential_response}

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
