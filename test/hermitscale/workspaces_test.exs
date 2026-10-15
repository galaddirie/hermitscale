defmodule Hermitscale.WorkspacesTest do
  use Hermitscale.DataCase, async: false

  import Hermitscale.AccountsFixtures
  import Hermitscale.WorkspacesFixtures

  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Workspaces
  alias Hermitscale.Workspaces.Workspace
  alias Hermitscale.WorkspacesTest.Client
  alias Hermitscale.WorkOSTest.Client, as: AuthClient

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
    start_supervised!({AuthClient, %{}})
    %{scope: user_scope_fixture()}
  end

  describe "organization workspaces" do
    test "creates a shared sprite from server-owned tenant and provider identities", %{
      scope: scope
    } do
      attrs =
        workspace_attrs(%{
          org_id: "org_forged",
          created_by_user_id: "user_forged",
          sprite_name: "stolen",
          sprite_data: %{},
          status: :ready
        })

      assert {:ok, workspace} = Workspaces.create_workspace(scope, attrs)
      assert workspace.org_id == scope.organization.id
      assert workspace.created_by_user_id == scope.user.id
      assert workspace.sprite_name != "stolen"
      assert workspace.status == :ready
      assert workspace.sprite_data["name"] == workspace.sprite_name
      assert [{:create, [name, []]}] = Client.calls()
      assert name == workspace.sprite_name
      assert workspace.last_error == nil
      refute :organization in Workspace.__schema__(:associations)
      refute :created_by_user in Workspace.__schema__(:associations)
    end

    test "validates user data before creating local or remote resources", %{scope: scope} do
      assert {:error, changeset} = Workspaces.create_workspace(scope, %{name: " "})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
      assert {:ok, []} = Workspaces.list_workspaces(scope)
      assert Client.calls() == []
    end

    test "any current member shares workspaces without role permissions or count quotas", %{
      scope: scope
    } do
      collaborator = organization_scope_fixture(user_fixture(), scope.organization)
      collaborator = put_in(collaborator.membership.permissions, [])

      for n <- 1..12 do
        workspace_fixture(collaborator, %{name: "Workspace #{n}"})
      end

      assert {:ok, workspaces} = Workspaces.list_workspaces(scope)
      assert length(workspaces) == 12
      assert length(Enum.uniq_by(workspaces, & &1.sprite_name)) == 12
      assert Enum.all?(workspaces, &(&1.created_by_user_id == collaborator.user.id))
      assert {:ok, _} = Workspaces.fetch_workspace(scope, hd(workspaces).id)
      refute Enum.any?(AuthClient.calls(), fn {op, _} -> op == :get_role end)
    end

    test "scopes all lookups and refetches provider identities from storage", %{scope: scope} do
      workspace = workspace_fixture(scope)
      other_scope = user_scope_fixture()
      assert {:ok, []} = Workspaces.list_workspaces(other_scope)
      assert {:error, :not_found} = Workspaces.fetch_workspace(other_scope, workspace.id)
      assert {:error, :not_found} = Workspaces.refresh_workspace(other_scope, workspace)
      assert {:error, :not_found} = Workspaces.delete_workspace(other_scope, workspace)

      forged = %{workspace | org_id: other_scope.organization.id, sprite_name: "stolen"}
      assert {:ok, ^workspace} = Workspaces.fetch_workspace(scope, forged)
      assert {:ok, %{operation: :execute}} = Workspaces.execute(scope, forged, "pwd")
      assert {:execute, [workspace.sprite_name, "pwd", [], []]} in Client.calls()
      refute Enum.any?(Client.calls(), fn {_op, args} -> "stolen" in args end)
    end

    test "accepts opaque organization and identity IDs", %{scope: scope} do
      scope =
        scope.user
        |> Map.put(:id, "identity:123")
        |> organization_scope_fixture(organization_fixture(%{id: "workspace:123"}))

      workspace = workspace_fixture(scope)
      assert workspace.org_id == "workspace:123"
      assert workspace.created_by_user_id == "identity:123"
    end

    test "anonymous, unscoped and forged memberships cannot reach data or Sprites", %{
      scope: scope
    } do
      for invalid <- [
            nil,
            Scope.for_user(scope.user),
            put_in(scope.membership.user_id, "forged"),
            put_in(scope.membership.org_id, "forged")
          ] do
        assert {:error, :forbidden} = Workspaces.list_workspaces(invalid)
        assert {:error, :forbidden} = Workspaces.create_workspace(invalid, workspace_attrs())
      end

      assert Client.calls() == []
      assert AuthClient.calls() == []
    end
  end

  describe "current membership" do
    test "revocation and inactive membership deny every operation using a stale scope", %{
      scope: scope
    } do
      workspace = workspace_fixture(scope)
      original_calls = Client.calls()

      for data <- [
            [],
            [
              %{
                "id" => "membership",
                "user_id" => scope.user.id,
                "organization_id" => scope.organization.id,
                "status" => "inactive",
                "role" => nil
              }
            ]
          ] do
        AuthClient.put_response(:list_memberships, {:ok, %{"data" => data}})
        assert {:error, :forbidden} = Workspaces.list_workspaces(scope)
        assert {:error, :forbidden} = Workspaces.fetch_workspace(scope, workspace)
        assert {:error, :forbidden} = Workspaces.create_workspace(scope, workspace_attrs())
        assert {:error, :forbidden} = Workspaces.refresh_workspace(scope, workspace)
        assert {:error, :forbidden} = Workspaces.delete_workspace(scope, workspace)

        for {operation, args} <- workspace_operations() do
          assert {:error, :forbidden} = apply(Workspaces, operation, [scope, workspace | args])
        end
      end

      assert Client.calls() == original_calls
    end

    test "fresh active membership requires no role", %{scope: scope} do
      AuthClient.put_response(
        :list_memberships,
        {:ok,
         %{
           "data" => [
             %{
               "id" => "membership",
               "user_id" => scope.user.id,
               "organization_id" => scope.organization.id,
               "status" => "active",
               "role" => nil
             }
           ]
         }}
      )

      assert {:ok, _} = Workspaces.create_workspace(scope, workspace_attrs())
    end

    test "membership dependency errors retain their actionable reasons", %{scope: scope} do
      workspace = workspace_fixture(scope)
      original_calls = Client.calls()

      for reason <- [:unavailable, :rate_limited, :invalid_response] do
        AuthClient.put_response(:list_memberships, {:error, reason})
        assert {:error, ^reason} = Workspaces.list_workspaces(scope)
        assert {:error, ^reason} = Workspaces.execute(scope, workspace, "pwd")
      end

      assert Client.calls() == original_calls
    end
  end

  describe "provider lifecycle" do
    test "retains local creation intent before the provider call and reconciles uncertain success",
         %{scope: scope} do
      Client.put_response(:create, fn name, [] ->
        workspace = Repo.get_by!(Workspace, sprite_name: name)
        assert workspace.status == :provisioning
        assert workspace.org_id == scope.organization.id
        {:error, :unavailable}
      end)

      assert {:error, :unavailable} = Workspaces.create_workspace(scope, workspace_attrs())
      assert {:ok, [pending]} = Workspaces.list_workspaces(scope)
      assert pending.status == :provisioning
      assert pending.last_error == %{"code" => "unavailable"}
      assert {:ok, recovered} = Workspaces.refresh_workspace(scope, pending.id)
      assert recovered.status == :ready
      assert recovered.last_error == nil
      assert recovered.id == pending.id
      assert Enum.count(Client.calls(), fn {op, _} -> op == :create end) == 1
    end

    test "failed provisioning can retry the retained name when the provider confirms absence", %{
      scope: scope
    } do
      Client.put_response(:create, {:error, :rate_limited})
      assert {:error, :rate_limited} = Workspaces.create_workspace(scope, workspace_attrs())
      assert {:ok, [pending]} = Workspaces.list_workspaces(scope)
      Client.put_response(:get, {:error, :not_found})

      Client.put_response(:create, fn name, [] -> {:ok, %{"name" => name, "status" => "cold"}} end)

      assert {:ok, workspace} = Workspaces.refresh_workspace(scope, pending.id)
      assert workspace.id == pending.id
      assert workspace.status == :ready
      assert {:create, [pending.sprite_name, []]} in Client.calls()
    end

    test "missing provisioned sprites are never silently replaced", %{scope: scope} do
      workspace = workspace_fixture(scope)
      Client.put_response(:get, {:error, :not_found})
      assert {:error, :not_found} = Workspaces.refresh_workspace(scope, workspace)
      assert {:ok, missing} = Workspaces.fetch_workspace(scope, workspace)
      assert missing.last_error == %{"code" => "not_found"}
      assert missing.status == :ready
      assert Enum.count(Client.calls(), fn {op, _} -> op == :create end) == 1
    end

    test "remote deletion succeeds before local data disappears", %{scope: scope} do
      workspace = workspace_fixture(scope)

      Client.put_response(:delete, fn name ->
        assert Repo.get_by!(Workspace, sprite_name: name).status == :deleting
        :ok
      end)

      assert {:ok, deleted} = Workspaces.delete_workspace(scope, workspace)
      assert deleted.id == workspace.id
      assert {:error, :not_found} = Workspaces.fetch_workspace(scope, workspace)
    end

    test "failed deletion retains intent and can be retried", %{scope: scope} do
      workspace = workspace_fixture(scope)
      Client.put_response(:delete, {:error, :unavailable})
      assert {:error, :unavailable} = Workspaces.delete_workspace(scope, workspace)
      assert {:ok, deleting} = Workspaces.fetch_workspace(scope, workspace)
      assert deleting.status == :deleting
      assert deleting.last_error == %{"code" => "unavailable"}
      assert {:error, :deleting} = Workspaces.refresh_workspace(scope, deleting)
      assert {:error, :deleting} = Workspaces.execute(scope, deleting, "pwd")
      Client.put_response(:delete, :ok)
      assert {:ok, _} = Workspaces.delete_workspace(scope, deleting)
    end

    test "a concurrent deletion cannot be overwritten by a refresh response", %{scope: scope} do
      workspace = workspace_fixture(scope)
      Client.put_response(:delete, {:error, :unavailable})

      Client.put_response(:get, fn name ->
        assert {:error, :unavailable} = Workspaces.delete_workspace(scope, workspace)
        {:ok, %{"name" => name, "status" => "running"}}
      end)

      assert {:error, :conflict} = Workspaces.refresh_workspace(scope, workspace)
      assert {:ok, deleting} = Workspaces.fetch_workspace(scope, workspace)
      assert deleting.status == :deleting
      assert deleting.last_error == %{"code" => "unavailable"}
    end

    test "deletion cannot discard an in-flight provisioning intent", %{scope: scope} do
      Client.put_response(:create, fn name, [] ->
        pending = Repo.get_by!(Workspace, sprite_name: name)
        assert {:error, :provisioning} = Workspaces.delete_workspace(scope, pending)
        {:ok, %{"name" => name, "status" => "cold"}}
      end)

      assert {:ok, workspace} = Workspaces.create_workspace(scope, workspace_attrs())
      assert workspace.status == :ready
      assert {:ok, ^workspace} = Workspaces.fetch_workspace(scope, workspace)
      refute Enum.any?(Client.calls(), fn {op, _} -> op == :delete end)
    end

    test "deletion cannot discard intent while failed creation is being retried", %{scope: scope} do
      Client.put_response(:create, {:error, :rate_limited})
      assert {:error, :rate_limited} = Workspaces.create_workspace(scope, workspace_attrs())
      assert {:ok, [failed]} = Workspaces.list_workspaces(scope)
      assert failed.status == :failed
      Client.put_response(:get, {:error, :not_found})

      Client.put_response(:create, fn name, [] ->
        pending = Repo.get_by!(Workspace, sprite_name: name)
        assert pending.status == :provisioning
        assert {:error, :provisioning} = Workspaces.delete_workspace(scope, pending)
        {:ok, %{"name" => name, "status" => "cold"}}
      end)

      assert {:ok, workspace} = Workspaces.refresh_workspace(scope, failed)
      assert workspace.status == :ready
      refute Enum.any?(Client.calls(), fn {op, _} -> op == :delete end)
    end

    test "unexpected provider statuses remain sanitized actionable errors", %{scope: scope} do
      Client.put_response(:create, {:error, {:unexpected_status, 302}})

      assert {:error, {:unexpected_status, 302}} =
               Workspaces.create_workspace(scope, workspace_attrs())

      assert {:ok, [pending]} = Workspaces.list_workspaces(scope)
      assert pending.status == :provisioning
      assert pending.last_error == %{"code" => "unexpected_status", "status" => 302}
      assert {:error, :provisioning} = Workspaces.delete_workspace(scope, pending)

      Client.put_response(:get, {:error, {:unexpected_status, 307}})
      assert {:error, {:unexpected_status, 307}} = Workspaces.refresh_workspace(scope, pending)
    end

    test "a failed reconciliation retry preserves an older uncertain creation", %{scope: scope} do
      Client.put_response(:create, {:error, :unavailable})
      assert {:error, :unavailable} = Workspaces.create_workspace(scope, workspace_attrs())
      assert {:ok, [pending]} = Workspaces.list_workspaces(scope)
      Client.put_response(:get, {:error, :not_found})
      Client.put_response(:create, {:error, :rate_limited})

      assert {:error, :rate_limited} = Workspaces.refresh_workspace(scope, pending)
      assert {:ok, retained} = Workspaces.fetch_workspace(scope, pending)
      assert retained.status == :provisioning
      assert retained.last_error == %{"code" => "rate_limited"}
      assert {:error, :provisioning} = Workspaces.delete_workspace(scope, retained)
    end

    test "definitively rejected retries remain eligible for deletion", %{scope: scope} do
      Client.put_response(:create, {:error, :rate_limited})
      assert {:error, :rate_limited} = Workspaces.create_workspace(scope, workspace_attrs())
      assert {:ok, [failed]} = Workspaces.list_workspaces(scope)
      Client.put_response(:get, {:error, :not_found})

      assert {:error, :rate_limited} = Workspaces.refresh_workspace(scope, failed)
      assert {:ok, retained} = Workspaces.fetch_workspace(scope, failed)
      assert retained.status == :failed
      assert {:ok, _} = Workspaces.delete_workspace(scope, retained)
    end

    test "a crash during a failed retry cannot roll back its retained provisioning intent", %{
      scope: scope
    } do
      Client.put_response(:create, {:error, :rate_limited})
      assert {:error, :rate_limited} = Workspaces.create_workspace(scope, workspace_attrs())
      assert {:ok, [failed]} = Workspaces.list_workspaces(scope)
      Client.put_response(:get, {:error, :not_found})
      Client.put_response(:create, fn _name, [] -> raise "simulated process failure" end)

      assert_raise RuntimeError, "simulated process failure", fn ->
        Workspaces.refresh_workspace(scope, failed)
      end

      assert {:ok, pending} = Workspaces.fetch_workspace(scope, failed)
      assert pending.status == :provisioning
      assert {:error, :provisioning} = Workspaces.delete_workspace(scope, pending)
    end

    test "another uncertain attempt before the creation lock cannot become a definitive failure",
         %{scope: scope} do
      replace_intent_on_membership_check(scope, 1)
      Client.put_response(:create, {:error, :rate_limited})

      assert {:error, :rate_limited} = Workspaces.create_workspace(scope, workspace_attrs())
      assert {:ok, [pending]} = Workspaces.list_workspaces(scope)
      assert pending.status == :provisioning
      assert {:error, :provisioning} = Workspaces.delete_workspace(scope, pending)
    end

    test "another uncertain attempt between retry preparation and reacquiring its lock is retained",
         %{scope: scope} do
      Client.put_response(:create, {:error, :rate_limited})
      assert {:error, :rate_limited} = Workspaces.create_workspace(scope, workspace_attrs())
      assert {:ok, [failed]} = Workspaces.list_workspaces(scope)
      Client.put_response(:get, {:error, :not_found})
      replace_intent_on_membership_check(scope, 3)

      assert {:error, :rate_limited} = Workspaces.refresh_workspace(scope, failed)
      assert {:ok, pending} = Workspaces.fetch_workspace(scope, failed)
      assert pending.status == :provisioning
      assert {:error, :provisioning} = Workspaces.delete_workspace(scope, pending)
    end

    test "a refresh waits for in-flight provisioning before contacting the provider", %{
      scope: scope
    } do
      # Separate committed connections are required to exercise the PostgreSQL row lock.
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
      supervisor = start_supervised!(Task.Supervisor)
      test_pid = self()

      Client.put_response(:create, fn name, [] ->
        pending = Repo.get_by!(Workspace, sprite_name: name)
        send(test_pid, {:create_started, self(), pending.id})

        receive do
          :release_create -> {:ok, %{"name" => name, "status" => "cold"}}
        after
          5_000 -> flunk("creation was not released")
        end
      end)

      Client.put_response(:get, fn name ->
        send(test_pid, :provider_get_started)
        {:ok, %{"name" => name, "status" => "cold"}}
      end)

      creation =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Workspaces.create_workspace(scope, workspace_attrs())
          end)
        end)

      assert_receive {:create_started, creation_pid, id}, 1_000

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from(workspace in Workspace, where: workspace.id == ^id))
        end)
      end)

      refresh =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            send(test_pid, :refresh_requested)
            Workspaces.refresh_workspace(scope, id)
          end)
        end)

      assert_receive :refresh_requested, 1_000
      refute_receive :provider_get_started
      send(creation_pid, :release_create)
      assert {:ok, created} = Task.await(creation)
      assert {:ok, refreshed} = Task.await(refresh)
      assert created.id == refreshed.id
      assert refreshed.status == :ready
      assert_receive :provider_get_started
      assert Enum.count(Client.calls(), fn {op, _} -> op == :create end) == 1
    end

    test "revocation during reconciliation prevents another creation effect", %{scope: scope} do
      Client.put_response(:create, {:error, :unavailable})
      assert {:error, :unavailable} = Workspaces.create_workspace(scope, workspace_attrs())
      assert {:ok, [pending]} = Workspaces.list_workspaces(scope)

      Client.put_response(:get, fn _name ->
        AuthClient.put_response(:list_memberships, {:ok, %{"data" => []}})
        {:error, :not_found}
      end)

      assert {:error, :forbidden} = Workspaces.refresh_workspace(scope, pending)
      assert Enum.count(Client.calls(), fn {op, _} -> op == :create end) == 1
    end
  end

  describe "sprite capabilities" do
    test "members can use every capability with caller options and provider results intact", %{
      scope: scope
    } do
      workspace = workspace_fixture(scope)
      collaborator = organization_scope_fixture(user_fixture(), scope.organization)

      for {operation, args} <- workspace_operations() do
        result = apply(Workspaces, operation, [collaborator, workspace | args])

        assert result ==
                 if(operation in [:delete_file, :delete_service],
                   do: :ok,
                   else: {:ok, %{operation: operation}}
                 )

        assert {operation, [workspace.sprite_name | args]} in Client.calls()
      end
    end

    test "every capability rejects foreign workspaces before contacting the provider", %{
      scope: scope
    } do
      workspace = workspace_fixture(scope)
      other = user_scope_fixture()
      original_calls = Client.calls()

      for {operation, args} <- workspace_operations() do
        assert {:error, :not_found} = apply(Workspaces, operation, [other, workspace | args])
      end

      assert Client.calls() == original_calls
    end

    test "every capability preserves provider errors", %{scope: scope} do
      workspace = workspace_fixture(scope)

      for {operation, args} <- workspace_operations() do
        Client.put_response(operation, {:error, :rate_limited})
        assert {:error, :rate_limited} = apply(Workspaces, operation, [scope, workspace | args])
      end
    end
  end

  defp replace_intent_on_membership_check(scope, check) do
    counter = start_supervised!({Agent, fn -> 0 end}, id: :membership_checks)

    AuthClient.put_response(:list_memberships, fn user_id, org_id ->
      current = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

      if current == check do
        # This check precedes the next row lock: simulate another completed uncertain attempt.
        Repo.get_by!(Workspace, org_id: scope.organization.id)
        |> Workspace.lifecycle_changeset(last_error: %{"code" => "unavailable"})
        |> Repo.update!()
      end

      membership_response(user_id, org_id)
    end)
  end
end
