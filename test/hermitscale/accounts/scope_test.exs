defmodule Hermitscale.Accounts.ScopeTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Accounts.Scope

  import Hermitscale.AccountsFixtures

  describe "tenant authority" do
    test "uses WorkOS organization IDs for matching resources" do
      scope = user_scope_fixture()
      org_id = scope.organization.id
      assert Scope.organization_id!(scope) == org_id
      assert :ok = Scope.assert_same_org!(scope, %{org_id: org_id})
    end

    test "rejects resources from another organization" do
      scope = user_scope_fixture()
      assert_raise MatchError, fn -> Scope.assert_same_org!(scope, %{org_id: "org_other"}) end
    end

    test "rejects membership assigned to a different user" do
      user = user_fixture()
      other = user_fixture()
      organization = organization_fixture()

      assert_raise FunctionClauseError, fn ->
        Scope.put_organization(Scope.for_user(user), organization, %{
          user_id: other.id,
          org_id: organization.id
        })
      end
    end

    test "organizationless callers cannot access tenant resources" do
      scope = Scope.for_user(user_fixture())
      assert_raise ArgumentError, fn -> Scope.organization_id!(scope) end
      assert Scope.for_user(nil) == nil
    end
  end
end
