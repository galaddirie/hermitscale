defmodule Hermitscale.AccountsTest do
  use ExUnit.Case, async: false
  import Hermitscale.AccountsFixtures
  alias Hermitscale.Accounts
  alias Hermitscale.WorkOSTest.Client

  setup do
    start_supervised!({Client, %{}})
    %{scope: user_scope_fixture()}
  end

  describe "personal provisioning and ordinary collaboration" do
    test "recovers a concurrent create by deterministic external ID and ensures Admin membership",
         %{scope: scope} do
      state = start_supervised!({Agent, fn -> 0 end}, id: :provisioning_state)

      Client.put_response(:get_organization_by_external_id, fn external ->
        assert external == "personal:" <> scope.user.id

        Agent.get_and_update(state, fn n ->
          {if(n == 0, do: {:error, :not_found}, else: {:ok, %{"id" => "org_personal"}}), n + 1}
        end)
      end)

      Client.put_response(:create_organization, {:error, :conflict})
      Client.put_response(:list_memberships, {:ok, %{"data" => []}})
      assert {:ok, %{"id" => "org_personal"}} = Accounts.ensure_personal_organization(scope.user)
      assert {:create_membership, [scope.user.id, "org_personal", "admin"]} in Client.calls()
      assert {:ok, %{"id" => "org_personal"}} = Accounts.ensure_personal_organization(scope.user)
    end

    test "existing personal memberships are preserved and invited users have the same actions", %{
      scope: scope
    } do
      assert {:ok, _org} = Accounts.ensure_personal_organization(scope.user)
      refute Enum.any?(Client.calls(), fn {op, _} -> op == :create_membership end)
      assert {:ok, _} = Accounts.invite(scope, "collaborator@example.test")

      assert {:invite_member,
              [scope.organization.id, scope.user.id, "collaborator@example.test", "runner"]} in Client.calls()

      assert {:ok, _} = Accounts.invite(scope, "editor@example.test", "editor")
      assert {:error, :invalid_role} = Accounts.invite(scope, "custom@example.test", "custom")
    end

    test "only members with management permission can invite, remove or assign roles", %{
      scope: scope
    } do
      for permissions <- [["workflows:run"], ~w(workflows:run workflows:edit workflows:activate)] do
        member = put_in(scope.membership.permissions, permissions)
        assert {:error, :forbidden} = Accounts.invite(member, "email@example.test", "admin")
        assert {:error, :forbidden} = Accounts.assign_role(member, "om_test", "admin")
        assert {:error, :forbidden} = Accounts.remove_member(member, "om_test")
      end

      Client.put_response(:get_membership, {:ok, %{"organization_id" => "org_other"}})
      assert {:error, :forbidden} = Accounts.assign_role(scope, "om_other", "runner")
      assert {:error, :forbidden} = Accounts.remove_member(scope, "om_other")
    end
  end
end
