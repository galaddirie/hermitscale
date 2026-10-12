defmodule Hermitscale.AuthorizationTest do
  use ExUnit.Case, async: false

  import Hermitscale.AccountsFixtures
  alias Hermitscale.Authorization
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.WorkOSTest.Client
  import Hermitscale.WorkOS.ClientFixtures

  describe "current execution membership" do
    setup do
      start_supervised!({Client, %{}})
      %{context: user_scope_fixture() |> Scope.execution_context()}
    end

    test "dependency failures preserve their actionable reasons", %{context: context} do
      membership =
        membership_fixture("om_123", %{
          "user_id" => context.actor_user_id,
          "organization_id" => context.organization_id
        })

      for operation <- [:list_memberships, :get_role],
          reason <- [:unavailable, :rate_limited, :invalid_response] do
        Client.put_response(:list_memberships, {:ok, %{"data" => [membership]}})
        Client.put_response(:get_role, {:ok, %{"permissions" => context.required_permissions}})
        Client.put_response(operation, {:error, reason})
        assert {:error, ^reason} = Authorization.execution_scope(context)
      end
    end
  end

  describe "verified permission claims" do
    test "permission slugs determine authority independently of role names" do
      scope = user_scope_fixture()
      scope = %{scope | membership: Map.put(scope.membership, :permissions, ["workflows:run"])}
      assert :ok = Authorization.authorize(scope, "workflows:run")
      assert {:error, :forbidden} = Authorization.authorize(scope, "workflows:edit")
      assert {:error, :forbidden} = Authorization.authorize(scope, "workflows:activate")
      assert {:error, :forbidden} = Authorization.authorize(scope, "connections:manage")
      assert {:error, :forbidden} = Authorization.authorize(scope, "members:manage")
    end

    test "claims cannot confer authority for a mismatched membership" do
      scope = user_scope_fixture()
      scope = put_in(scope.membership.org_id, "org_forged")
      assert {:error, :forbidden} = Authorization.authorize(scope, "workflows:run")
      assert {:error, :forbidden} = Authorization.authorize(nil, "workflows:run")
    end
  end
end
