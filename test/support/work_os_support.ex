defmodule Hermitscale.WorkOSTest.JWTVerifier do
  @moduledoc false

  def verify(token, opts \\ []) when is_binary(token) do
    with {:ok, claims} when is_map(claims) <- Jason.decode(token),
         :ok <- validate_equal(claims["sub"], Keyword.get(opts, :subject)),
         :ok <- validate_equal(claims["sid"], Keyword.get(opts, :session_id)),
         :ok <- validate_expiry(claims["exp"], Keyword.get(opts, :allow_expired, false)) do
      {:ok, claims}
    else
      _reason -> {:error, :invalid_access_token}
    end
  end

  defp validate_equal(_actual, nil), do: :ok
  defp validate_equal(value, value), do: :ok
  defp validate_equal(_actual, _expected), do: {:error, :claim_mismatch}

  defp validate_expiry(expiration, true) when is_integer(expiration), do: :ok

  defp validate_expiry(expiration, false) when is_integer(expiration) do
    if expiration > System.system_time(:second),
      do: :ok,
      else: {:error, :expired}
  end

  defp validate_expiry(_expiration, _allow_expired), do: {:error, :expired}
end

defmodule Hermitscale.WorkOSTest.Client do
  @moduledoc false

  use Agent

  def start_link(initial \\ %{}) do
    initial = Map.new(initial)
    Agent.start_link(fn -> %{responses: initial, calls: []} end, name: __MODULE__)
  end

  def put_response(operation, response) do
    Agent.update(__MODULE__, &put_in(&1, [:responses, operation], response))
  end

  def calls do
    Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  end

  def authorization_url(state, opts \\ []) do
    respond(
      :authorization_url,
      [state, opts],
      {:ok, "https://api.workos.com/authorize?state=#{state}"}
    )
  end

  def authenticate_with_code(code, metadata \\ %{}) do
    respond(:authenticate_with_code, [code, metadata], {:error, :not_configured})
  end

  def authenticate_with_refresh_token(refresh_token, organization_id, metadata \\ %{}) do
    respond(
      :authenticate_with_refresh_token,
      [refresh_token, organization_id, metadata],
      {:error, :not_configured}
    )
  end

  def jwks do
    respond(:jwks, [], {:ok, %{"keys" => []}})
  end

  def list_events(cursor, event_types, opts \\ []) do
    respond(
      :list_events,
      [cursor, event_types, opts],
      {:ok, %{"data" => [], "list_metadata" => %{"after" => nil}}}
    )
  end

  def list_users(cursor \\ nil, opts \\ []) do
    respond(
      :list_users,
      [cursor, opts],
      {:ok, %{"data" => [], "list_metadata" => %{"after" => nil}}}
    )
  end

  def list_organizations(cursor \\ nil, opts \\ []) do
    respond(
      :list_organizations,
      [cursor, opts],
      {:ok, %{"data" => [], "list_metadata" => %{"after" => nil}}}
    )
  end

  def get_organization_by_external_id(external_id) do
    respond(:get_organization_by_external_id, [external_id], {:error, :not_found})
  end

  def create_organization(name, external_id) do
    respond(:create_organization, [name, external_id], {:error, :not_configured})
  end

  def list_organization_memberships(organization_id, cursor \\ nil, opts \\ []) do
    respond(
      :list_organization_memberships,
      [organization_id, cursor, opts],
      {:ok, %{"data" => [], "list_metadata" => %{"after" => nil}}}
    )
  end

  def create_organization_membership(organization_id, user_id, role_slug) do
    respond(
      :create_organization_membership,
      [organization_id, user_id, role_slug],
      {:error, :not_configured}
    )
  end

  def update_organization_membership(membership_id, role_slug) do
    respond(
      :update_organization_membership,
      [membership_id, role_slug],
      {:error, :not_configured}
    )
  end

  def deactivate_organization_membership(membership_id) do
    respond(
      :deactivate_organization_membership,
      [membership_id],
      {:error, :not_configured}
    )
  end

  def list_sessions(user_id, cursor \\ nil, opts \\ []) do
    respond(
      :list_sessions,
      [user_id, cursor, opts],
      {:ok, %{"data" => [], "list_metadata" => %{"after" => nil}}}
    )
  end

  def list_providers(user_id, organization_id \\ nil) do
    respond(:list_providers, [user_id, organization_id], {:ok, %{"data" => []}})
  end

  def authorize_connection(provider, user_id, organization_id, return_to) do
    respond(
      :authorize_connection,
      [provider, user_id, organization_id, return_to],
      {:ok, %{"url" => "https://api.workos.com/pipes/authorize"}}
    )
  end

  def get_connected_account(provider, user_id, organization_id) do
    respond(
      :get_connected_account,
      [provider, user_id, organization_id],
      {:error, :not_found}
    )
  end

  def delete_connected_account(provider, user_id, organization_id) do
    respond(:delete_connected_account, [provider, user_id, organization_id], {:ok, %{}})
  end

  def fetch_oauth_token(provider, user_id, organization_id) do
    respond(
      :fetch_oauth_token,
      [provider, user_id, organization_id],
      {:error, :not_configured}
    )
  end

  def revoke_session(session_id) do
    respond(:revoke_session, [session_id], {:ok, %{}})
  end

  def delete_user(user_id) do
    respond(:delete_user, [user_id], {:ok, %{}})
  end

  def logout_url(session_id, return_to \\ nil) do
    respond(
      :logout_url,
      [session_id, return_to],
      "https://api.workos.com/user_management/sessions/logout?session_id=#{session_id}"
    )
  end

  defp respond(operation, args, default) do
    case Process.whereis(__MODULE__) do
      nil ->
        default

      _pid ->
        Agent.get_and_update(__MODULE__, fn state ->
          response = Map.get(state.responses, operation, default)
          {resolve(response, args), %{state | calls: [{operation, args} | state.calls]}}
        end)
    end
  end

  defp resolve(response, args) when is_function(response), do: apply(response, args)
  defp resolve(response, _args), do: response
end
