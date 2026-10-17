defmodule Hermitscale.WorkspacesTest do
  use Hermitscale.DataCase, async: false

  import Hermitscale.AccountsFixtures
  import Hermitscale.WorkspacesFixtures

  alias Hermitscale.Workspaces
  alias Hermitscale.WorkspacesTest.Client

  setup do
    previous = Application.get_env(:hermitscale, Workspaces)
    Application.put_env(:hermitscale, Workspaces, client: Client)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:hermitscale, Workspaces)
        value -> Application.put_env(:hermitscale, Workspaces, value)
      end
    end)

    start_supervised!({Client, []})
    %{scope: user_scope_fixture()}
  end

  describe "create_workspace/2" do
    test "creates the Sprite, then records server-owned identities", %{scope: scope} do
      attrs = workspace_attrs(%{org_id: "org_forged", created_by_user_id: "x", sprite_name: "x"})

      assert {:ok, workspace} = Workspaces.create_workspace(scope, attrs)
      assert workspace.org_id == scope.organization.id
      assert workspace.created_by_user_id == scope.user.id
      assert "hs-" <> _ = workspace.sprite_name
      assert [{:create, [name]}] = Client.calls()
      assert name == workspace.sprite_name
      assert {:ok, [^workspace]} = Workspaces.list_workspaces(scope)
    end

    test "validates before contacting the provider", %{scope: scope} do
      assert {:error, changeset} = Workspaces.create_workspace(scope, %{name: " "})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
      assert Client.calls() == []
    end

    test "stores nothing when the provider fails", %{scope: scope} do
      Client.put_response(:create, {:error, {:http_error, 500, "boom"}})

      assert {:error, {:http_error, 500, "boom"}} =
               Workspaces.create_workspace(scope, workspace_attrs())

      assert {:ok, []} = Workspaces.list_workspaces(scope)
    end
  end

  describe "delete_workspace/2" do
    test "deletes the Sprite, then the record", %{scope: scope} do
      workspace = workspace_fixture(scope)

      assert {:ok, _deleted} = Workspaces.delete_workspace(scope, workspace.id)
      assert {:delete, [workspace.sprite_name]} in Client.calls()
      assert {:error, :not_found} = Workspaces.fetch_workspace(scope, workspace.id)
    end

    test "keeps the record when the provider fails", %{scope: scope} do
      workspace = workspace_fixture(scope)
      Client.put_response(:delete, {:error, {:http_error, 500, "boom"}})

      assert {:error, {:http_error, 500, "boom"}} = Workspaces.delete_workspace(scope, workspace)
      assert {:ok, ^workspace} = Workspaces.fetch_workspace(scope, workspace.id)
    end
  end

  describe "authorization" do
    test "workspaces are shared within an organization and hidden from others", %{scope: scope} do
      workspace = workspace_fixture(scope)
      teammate = organization_scope_fixture(user_fixture(), scope.organization)
      outsider = user_scope_fixture()

      assert {:ok, [^workspace]} = Workspaces.list_workspaces(teammate)
      assert {:ok, []} = Workspaces.list_workspaces(outsider)
      assert {:error, :not_found} = Workspaces.fetch_workspace(outsider, workspace.id)
      assert {:error, :not_found} = Workspaces.delete_workspace(outsider, workspace)
      assert {:error, :not_found} = Workspaces.execute(outsider, workspace, "pwd")
    end

    test "requires the workflows:run permission", %{scope: scope} do
      workspace = workspace_fixture(scope)
      denied = put_in(scope.membership.permissions, [])

      assert {:error, :forbidden} = Workspaces.list_workspaces(denied)
      assert {:error, :forbidden} = Workspaces.create_workspace(denied, workspace_attrs())
      assert {:error, :forbidden} = Workspaces.execute(denied, workspace, "pwd")
      assert {:error, :forbidden} = Workspaces.list_workspaces(nil)
    end

    test "changing the network policy also requires connections:manage", %{scope: scope} do
      workspace = workspace_fixture(scope)
      runner = put_in(scope.membership.permissions, ["workflows:run"])

      assert {:ok, _policy} = Workspaces.get_network_policy(runner, workspace)
      assert {:error, :forbidden} = Workspaces.put_network_policy(runner, workspace, [])
      refute Enum.any?(Client.calls(), &match?({:put_network_policy, _args}, &1))
    end

    test "uses the stored Sprite name, not a supplied struct's", %{scope: scope} do
      workspace = workspace_fixture(scope)
      forged = %{workspace | sprite_name: "stolen"}

      assert {:ok, %{operation: :execute}} = Workspaces.execute(scope, forged, "pwd")
      assert {:execute, [workspace.sprite_name, "pwd", [], []]} in Client.calls()
    end
  end

  test "every Sprite operation passes its arguments through", %{scope: scope} do
    workspace = workspace_fixture(scope)

    for {function, operation, args} <- workspace_operations() do
      assert {:ok, %{operation: ^operation}} =
               apply(Workspaces, function, [scope, workspace.id | args])

      assert {operation, [workspace.sprite_name | args]} in Client.calls()
    end
  end
end
