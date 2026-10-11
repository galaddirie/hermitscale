defmodule Hermitscale.Integrations.ConnectedAccountsTest do
  use Hermitscale.DataCase, async: false

  alias Hermitscale.Accounts
  alias Hermitscale.Integrations.{ConnectedAccount, ConnectedAccounts}
  alias Hermitscale.Repo
  alias Hermitscale.WorkOSTest.Client

  import Hermitscale.AccountsFixtures

  @read_scope "https://www.googleapis.com/auth/spreadsheets.readonly"
  @write_scope "https://www.googleapis.com/auth/spreadsheets"

  setup do
    start_supervised!({Client, %{}})

    previous = Application.get_env(:hermitscale, ConnectedAccounts, [])
    Application.put_env(:hermitscale, ConnectedAccounts, Keyword.put(previous, :client, Client))

    on_exit(fn -> Application.put_env(:hermitscale, ConnectedAccounts, previous) end)
  end

  describe "connection consent" do
    test "creates a tenant-bound, expiring intent before redirecting to Pipes" do
      user = user_fixture()
      scope = user_scope_fixture(user)

      assert {:ok, %{url: url, intent: intent}} =
               ConnectedAccounts.begin_connect(
                 scope,
                 "google",
                 :private,
                 "https://app.example/users/settings/connected-accounts"
               )

      assert intent.owner_user_id == user.id
      assert intent.org_id == scope.organization.id
      assert intent.provider_slug == "google"
      assert intent.sharing_mode == :private
      assert DateTime.after?(intent.expires_at, DateTime.utc_now(:second))
      assert ConnectedAccounts.authorization_url_allowed?(url)

      assert [
               {:authorize_connection,
                [
                  "google",
                  workos_user_id,
                  nil,
                  return_to
                ]}
             ] = Client.calls()

      assert workos_user_id == user.workos_user_id
      assert URI.decode_query(URI.parse(return_to).query)["intent"]
    end

    test "allows only owners and admins to grant a connection to a shared organization" do
      user = user_fixture()
      organization = shared_organization_fixture()
      organization_membership_fixture(user, organization, role: :member)
      member_scope = organization_scope_fixture(user, organization)

      assert {:error, :unauthorized} =
               ConnectedAccounts.begin_connect(
                 member_scope,
                 "google",
                 :organization,
                 "https://app.example/return"
               )

      owner = user_fixture()
      organization_membership_fixture(owner, organization, role: :owner)
      owner_scope = organization_scope_fixture(owner, organization)

      assert {:ok, %{intent: %{sharing_mode: :organization}}} =
               ConnectedAccounts.begin_connect(
                 owner_scope,
                 "google",
                 :organization,
                 "https://app.example/return"
               )
    end

    test "preserves the local sharing grant when the event wins the browser-return race" do
      user = user_fixture()
      organization = shared_organization_fixture()
      organization_membership_fixture(user, organization, role: :owner)
      scope = organization_scope_fixture(user, organization)
      remote = remote_account(user, organization, "2026-07-26T15:00:00.000000Z")

      assert {:ok, %{intent: intent}} =
               ConnectedAccounts.begin_connect(
                 scope,
                 "google",
                 :organization,
                 "https://app.example/connections"
               )

      [{:authorize_connection, [_provider, _user, _org, return_to]}] = Client.calls()
      token = URI.decode_query(URI.parse(return_to).query)["intent"]

      assert {:ok, %ConnectedAccount{sharing_mode: :private}} =
               ConnectedAccounts.sync_event(
                 "pipes.connected_account.connected",
                 remote
               )

      Client.put_response(:get_connected_account, {:ok, remote})

      assert {:ok, %ConnectedAccount{sharing_mode: :organization}} =
               ConnectedAccounts.refresh_intent(scope, token)

      assert Repo.reload!(intent).consumed_at
    end
  end

  describe "runtime authorization and token vending" do
    test "vends a token only after tenant, provider, state, membership, and scopes pass" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      account = connected_account_fixture(user, scope.organization)

      Client.put_response(
        :fetch_oauth_token,
        {:ok,
         %{
           access_token: "ephemeral-provider-token",
           expires_at: ~U[2026-07-26 16:00:00Z],
           scopes: [@read_scope, @write_scope],
           missing_scopes: []
         }}
      )

      assert {:ok,
              %{
                access_token: "ephemeral-provider-token",
                scopes: [@read_scope, @write_scope]
              }} =
               ConnectedAccounts.fetch_oauth_token(
                 scope.organization.id,
                 "google.oauth",
                 account.id,
                 [@read_scope]
               )

      assert {:error, :connected_account_not_found} =
               ConnectedAccounts.fetch_oauth_token(
                 Ecto.UUID.generate(),
                 "google.oauth",
                 account.id,
                 [@read_scope]
               )

      assert {:error, :connected_account_not_found} =
               ConnectedAccounts.fetch_oauth_token(
                 scope.organization.id,
                 "another.provider",
                 account.id,
                 [@read_scope]
               )
    end

    test "rejects insufficient local or freshly returned scopes" do
      user = user_fixture()
      scope = user_scope_fixture(user)

      account =
        connected_account_fixture(user, scope.organization, granted_scopes: [@read_scope])

      assert {:error, {:missing_scopes, [@write_scope]}} =
               ConnectedAccounts.fetch_oauth_token(
                 scope.organization.id,
                 "google.oauth",
                 account.id,
                 [@write_scope]
               )

      assert Client.calls() == []

      Client.put_response(
        :fetch_oauth_token,
        {:ok,
         %{
           access_token: "ephemeral-provider-token",
           expires_at: nil,
           scopes: [@read_scope],
           missing_scopes: [@write_scope]
         }}
      )

      assert {:error, {:missing_scopes, [@write_scope]}} =
               ConnectedAccounts.fetch_oauth_token(
                 scope.organization.id,
                 "google.oauth",
                 account.id,
                 [@read_scope]
               )
    end

    test "marks the account for user action when Pipes requires reauthorization" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      account = connected_account_fixture(user, scope.organization)
      Client.put_response(:fetch_oauth_token, {:error, :needs_reauthorization})

      assert {:error, :needs_reauthorization} =
               ConnectedAccounts.fetch_oauth_token(
                 scope.organization.id,
                 "google.oauth",
                 account.id,
                 [@read_scope]
               )

      assert Repo.get!(ConnectedAccount, account.id).state == :needs_reauthorization
    end

    test "requires an explicit organization grant and an active owner membership" do
      user = user_fixture()
      organization = shared_organization_fixture()
      membership = organization_membership_fixture(user, organization, role: :owner)

      account =
        connected_account_fixture(user, organization, sharing_mode: :private)

      assert {:error, :organization_grant_required} =
               ConnectedAccounts.fetch_oauth_token(
                 organization.id,
                 "google.oauth",
                 account.id,
                 [@read_scope]
               )

      account
      |> ConnectedAccount.sharing_changeset(%{sharing_mode: :organization})
      |> Repo.update!()

      membership
      |> Accounts.OrganizationMembership.changeset(%{status: :inactive})
      |> Repo.update!()

      assert {:error, :owner_membership_inactive} =
               ConnectedAccounts.fetch_oauth_token(
                 organization.id,
                 "google.oauth",
                 account.id,
                 [@read_scope]
               )
    end
  end

  describe "sharing and disconnection" do
    test "owners can grant and revoke organization access" do
      user = user_fixture()
      organization = shared_organization_fixture()
      organization_membership_fixture(user, organization, role: :owner)
      scope = organization_scope_fixture(user, organization)
      connected_account_fixture(user, organization, sharing_mode: :private)

      assert {:ok, %ConnectedAccount{sharing_mode: :organization}} =
               ConnectedAccounts.set_sharing(scope, "google", :organization)

      assert {:ok, %ConnectedAccount{sharing_mode: :private}} =
               ConnectedAccounts.set_sharing(scope, "google", :private)
    end

    test "a failed remote delete leaves vending blocked in disconnecting state" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      account = connected_account_fixture(user, scope.organization)
      Client.put_response(:delete_connected_account, {:error, :unavailable})

      assert {:error, :unavailable} = ConnectedAccounts.disconnect(scope, "google")
      assert Repo.get!(ConnectedAccount, account.id).state == :disconnecting

      assert {:error, :connected_account_unavailable} =
               ConnectedAccounts.fetch_oauth_token(
                 scope.organization.id,
                 "google.oauth",
                 account.id,
                 [@read_scope]
               )
    end
  end

  defp shared_organization_fixture do
    organization_fixture(
      workos_organization_id: "org_#{System.unique_integer([:positive])}",
      provisioning_state: :ready,
      workos_updated_at: DateTime.utc_now(:microsecond)
    )
  end

  defp remote_account(user, organization, timestamp) do
    %{
      "id" => "connected_account_#{System.unique_integer([:positive])}",
      "user_id" => user.workos_user_id,
      "organization_id" => organization.workos_organization_id,
      "provider_slug" => "google",
      "state" => "connected",
      "scopes" => [@read_scope, @write_scope],
      "created_at" => timestamp,
      "updated_at" => timestamp
    }
  end
end
