defmodule Hermitscale.AuthorizationTest do
  use ExUnit.Case, async: true

  import Hermitscale.AccountsFixtures
  alias Hermitscale.Authorization

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
