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

  def list_org_providers(org_id) do
    respond(
      :list_org_providers,
      [org_id],
      {:ok,
       %{
         "data" => [
           %{
             "slug" => "test.credentials",
             "connected_accounts" => [account("data_test", org_id, ["scope:a"])]
           },
           %{
             "slug" => "google",
             "connected_accounts" => [account("data_google", org_id, google_scopes())]
           }
         ]
       }}
    )
  end

  defp account(id, org, scopes),
    do: %{
      "id" => id,
      "organization_id" => org,
      "user_id" => nil,
      "auth_method" => "oauth",
      "state" => "connected",
      "scopes" => scopes
    }

  defp google_scopes,
    do: [
      "https://www.googleapis.com/auth/spreadsheets",
      "https://www.googleapis.com/auth/spreadsheets.readonly"
    ]

  def vend_credentials(provider, user_id, org_id, account_id) do
    respond(
      :vend_credentials,
      [provider, user_id, org_id, account_id],
      {:ok,
       %{
         auth_method: "oauth",
         value: "access_123",
         scopes: ["scope:a"] ++ google_scopes(),
         missing_scopes: [],
         expires_at: nil
       }}
    )
  end

  def authorize_connection(provider, user_id, org_id, return_to, account_id \\ nil),
    do:
      respond(
        :authorize_connection,
        [provider, user_id, org_id, return_to, account_id],
        {:ok, %{"url" => "https://api.workos.com/pipes/authorize"}}
      )

  def rotate_api_key(provider, user, org, account, secret),
    do: respond(:rotate_api_key, [provider, user, org, account, secret], {:ok, %{}})

  def disconnect_account(provider, org, account),
    do: respond(:disconnect_account, [provider, org, account], {:ok, %{}})

  def list_memberships(user, org \\ nil),
    do:
      respond(
        :list_memberships,
        [user, org],
        {:ok,
         %{
           "data" => [
             %{
               "id" => "om_test",
               "user_id" => user,
               "organization_id" => org || "org_test",
               "status" => "active",
               "role" => %{"slug" => "admin"}
             }
           ]
         }}
      )

  def get_role(slug),
    do:
      respond(
        :get_role,
        [slug],
        {:ok,
         %{
           "slug" => slug,
           "permissions" => Hermitscale.AccountsFixtures.role_permissions_fixture(slug)
         }}
      )

  def get_organization_by_external_id(external),
    do:
      respond(
        :get_organization_by_external_id,
        [external],
        {:ok, %{"id" => "org_personal", "external_id" => external}}
      )

  def get_organization(id),
    do: respond(:get_organization, [id], {:ok, %{"id" => id, "name" => "Workspace"}})

  def create_organization(attrs),
    do: respond(:create_organization, [attrs], {:ok, Map.put(attrs, "id", "org_personal")})

  def create_membership(user, org, role),
    do: respond(:create_membership, [user, org, role], {:ok, %{"id" => "om_test"}})

  def get_membership(id), do: respond(:get_membership, [id], {:error, :not_found})
  def update_membership(id, role), do: respond(:update_membership, [id, role], {:ok, %{}})
  def remove_membership(id), do: respond(:remove_membership, [id], {:ok, %{}})

  def invite_member(org, user, email, role),
    do: respond(:invite_member, [org, user, email, role], {:ok, %{}})

  def revoke_session(session_id) do
    respond(:revoke_session, [session_id], {:ok, %{}})
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
