defmodule Hermitscale.Integrations.ConnectedAccountsTest do
  use ExUnit.Case, async: false
  import Hermitscale.AccountsFixtures
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Integrations.{ConnectedAccounts, CredentialRef}
  alias Hermitscale.WorkOSTest.Client

  setup do
    start_supervised!({Client, %{}})
    scope = user_scope_fixture()

    {:ok, ref} =
      ConnectedAccounts.credential_ref(
        Scope.execution_context(scope),
        %{"provider" => "test.credentials", "account_id" => "data_test"},
        ["scope:a"]
      )

    %{scope: scope, ref: ref}
  end

  describe "org readiness and immediate vending" do
    test "only one compatible account is selected automatically, and ambiguity needs a choice", %{
      scope: scope
    } do
      assert {:ok, %{"account_id" => "data_test"}} =
               ConnectedAccounts.select(scope, "test.credentials", ["scope:a"])

      account = %{
        "id" => "data_second",
        "organization_id" => scope.organization.id,
        "user_id" => nil,
        "auth_method" => "oauth",
        "state" => "connected",
        "scopes" => ["scope:a"]
      }

      Client.put_response(
        :list_org_providers,
        {:ok,
         %{
           "data" => [
             %{
               "slug" => "test.credentials",
               "connected_accounts" => [account, %{account | "id" => "data_test"}]
             }
           ]
         }}
      )

      assert {:error, :account_selection_required} =
               ConnectedAccounts.select(scope, "test.credentials", ["scope:a"])

      assert {:ok, ref} =
               ConnectedAccounts.credential_ref(
                 Scope.execution_context(scope),
                 %{"provider" => "test.credentials", "account_id" => "data_test"},
                 ["scope:a"]
               )

      assert ref.account_id == "data_test"
    end

    test "organization and provider equality cannot be forged through an account ID", %{
      scope: scope
    } do
      Client.put_response(
        :list_org_providers,
        {:ok,
         %{
           "data" => [
             %{
               "slug" => "test.credentials",
               "connected_accounts" => [
                 %{
                   "id" => "data_test",
                   "organization_id" => "org_foreign",
                   "user_id" => nil,
                   "auth_method" => "oauth",
                   "state" => "connected",
                   "scopes" => ["scope:a"]
                 }
               ]
             }
           ]
         }}
      )

      assert {:error, :account_not_found} =
               ConnectedAccounts.credential_ref(
                 Scope.execution_context(scope),
                 %{"provider" => "test.credentials", "account_id" => "data_test"},
                 []
               )

      assert {:error, :missing_execution_identity} =
               ConnectedAccounts.credential_ref(
                 nil,
                 %{"provider" => "test.credentials", "account_id" => "data_test"},
                 []
               )
    end

    test "vends every request against the stable selected account", %{ref: ref} do
      assert %CredentialRef{} = ref
      for _ <- 1..2, do: assert({:ok, %{value: "access_123"}} = ConnectedAccounts.vend(ref))
      assert Enum.count(Client.calls(), fn {op, _} -> op == :vend_credentials end) == 2

      assert {:vend_credentials,
              [
                "test.credentials",
                ref.execution_context.actor_user_id,
                ref.execution_context.organization_id,
                "data_test"
              ]} in Client.calls()
    end

    test "oauth missing consent and scope failures are actionable", %{ref: ref} do
      Client.put_response(
        :vend_credentials,
        {:ok, %{auth_method: "oauth", value: "secret", scopes: [], missing_scopes: ["scope:a"]}}
      )

      assert {:error, :insufficient_scopes} = ConnectedAccounts.vend(ref)
      Client.put_response(:vend_credentials, {:error, :needs_reauthorization})
      assert {:error, :needs_reauthorization} = ConnectedAccounts.vend(ref)
    end

    test "api keys use the same reference and current membership checks", %{ref: ref} do
      Client.put_response(
        :vend_credentials,
        {:ok, %{auth_method: "api_key", value: "opaque-key", scopes: [], missing_scopes: []}}
      )

      assert {:ok, %{auth_method: "api_key", value: "opaque-key"}} = ConnectedAccounts.vend(ref)
      Client.put_response(:list_memberships, {:ok, %{"data" => []}})
      assert {:error, :execution_actor_ineligible} = ConnectedAccounts.vend(ref)
    end

    test "current permission removal prevents vending despite an old run reference", %{ref: ref} do
      Client.put_response(:get_role, {:ok, %{"permissions" => []}})
      assert {:error, :execution_actor_ineligible} = ConnectedAccounts.vend(ref)
      refute Enum.any?(Client.calls(), fn {op, _} -> op == :vend_credentials end)
    end

    test "runners and editors cannot manage shared connections", %{scope: scope} do
      for permissions <- [["workflows:run"], ~w(workflows:run workflows:edit workflows:activate)] do
        member = put_in(scope.membership.permissions, permissions)

        assert {:error, :forbidden} =
                 ConnectedAccounts.connect(member, "test.credentials", "https://example.test")

        assert {:error, :forbidden} =
                 ConnectedAccounts.rotate(member, "test.credentials", "data_test", "secret")

        assert {:error, :forbidden} =
                 ConnectedAccounts.disconnect(member, "test.credentials", "data_test")
      end
    end

    test "rejects a connection from another provider or organization", %{scope: scope} do
      assert {:error, :invalid_connection} =
               ConnectedAccounts.validate_selection(
                 %{"provider" => "google", "account_id" => "data_test"},
                 "test.credentials"
               )

      assert {:error, :account_not_found} =
               ConnectedAccounts.credential_ref(
                 Scope.execution_context(scope),
                 %{"provider" => "google", "account_id" => "data_test"},
                 []
               )

      assert {:error, :unknown_provider} =
               ConnectedAccounts.validate_selection(
                 %{"provider" => "undeployed", "account_id" => "data_test"},
                 nil
               )
    end
  end
end
