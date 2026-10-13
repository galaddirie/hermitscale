defmodule Hermitscale.Workspaces.WorkspacesTest do
  use Hermitscale.DataCase, async: false

  import Hermitscale.WorkspacesFixtures
  alias Hermitscale.Workspaces

  setup do
    start_supervised!(Hermitscale.WorkOSTest.Client)
    prior = Application.get_env(:hermitscale, :workspace_management_adapter)

    Application.put_env(
      :hermitscale,
      :workspace_management_adapter,
      Hermitscale.WorkspacesManagementFake
    )

    on_exit(fn ->
      if prior do
        Application.put_env(:hermitscale, :workspace_management_adapter, prior)
      else
        Application.delete_env(:hermitscale, :workspace_management_adapter)
      end
    end)

    %{scope: workspace_scope_fixture()}
  end

  describe "durable workspace identity" do
    test "same owner resolves to the same retained identity with server-owned authority", %{
      scope: scope
    } do
      owner = Ecto.UUID.generate()

      attrs =
        Map.merge(workspace_attrs(), %{
          sprite_name: "caller-sprite",
          org_id: "other",
          created_by_user_id: "other",
          token: "secret"
        })

      assert {:ok, workspace} = Workspaces.ensure_workspace(scope, owner, attrs)
      assert {:ok, retry} = Workspaces.ensure_workspace(scope, owner, workspace_attrs())
      assert retry.id == workspace.id
      assert workspace.sprite_name == "hs-" <> workspace.id
      assert workspace.org_id == scope.organization.id
      assert workspace.created_by_user_id == scope.user.id
      assert workspace.resource_state == :provision_pending
      refute_receive {:management_allocate, _}

      assert {:error, :owner_key_conflict} =
               Workspaces.ensure_workspace(
                 scope,
                 owner,
                 workspace_attrs(%{repository: "github:other/project"})
               )
    end

    test "stored reads never contact the provider and cannot cross organizations", %{scope: scope} do
      workspace = workspace_fixture(scope)
      assert {:ok, ^workspace} = Workspaces.get_workspace(scope, workspace.id)

      assert {:error, :not_found} =
               Workspaces.get_workspace(workspace_scope_fixture(), workspace.id)

      assert {:error, :not_found} = Workspaces.get_workspace(scope, "invalid-id")
      assert {:error, :forbidden} = Workspaces.get_workspace(nil, workspace.id)

      assert {:error, :forbidden} =
               Workspaces.ensure_workspace(
                 put_in(scope.membership.permissions, []),
                 "owner",
                 workspace_attrs()
               )

      assert Hermitscale.WorkOSTest.Client.calls() == []
      refute_receive {:management_allocate, _}
    end

    test "malformed owner and operation keys fail at the context boundary", %{scope: scope} do
      assert {:error, :invalid_owner_key} =
               Workspaces.ensure_workspace(scope, 42, workspace_attrs())

      assert {:error, :invalid_workspace_attributes} =
               Workspaces.ensure_workspace(scope, "owner", "wrong")

      workspace = workspace_fixture(scope)

      assert {:error, :invalid_operation_key} =
               Workspaces.admit_lease(scope, workspace.id, 42, lease_deadline())

      assert {:error, :forbidden} =
               Workspaces.admit_lease(nil, workspace.id, "turn", lease_deadline())
    end

    test "provisioning records retained storage once and repeated requests do not wake it", %{
      scope: scope
    } do
      workspace = workspace_fixture(scope)
      assert {:ok, retained} = Workspaces.provision_workspace(scope, workspace.id)
      assert retained.resource_state == :retained
      assert retained.compute_state == :sleeping
      assert_receive {:management_allocate, id}
      assert id == workspace.id
      assert {:ok, ^retained} = Workspaces.provision_workspace(scope, workspace.id)
      refute_receive {:management_allocate, _}
    end
  end

  describe "exclusive writer leases" do
    test "locked validation reloads generation and can participate in an enclosing commit", %{
      scope: scope
    } do
      workspace = workspace_fixture(scope)
      assert {:ok, lease} = Workspaces.admit_lease(scope, workspace.id, "turn", lease_deadline())
      assert {:ok, ^lease} = Workspaces.validate_lease(scope, lease.id, lock: true)

      assert {:ok, ^lease} =
               Repo.transaction(fn ->
                 assert {:ok, current} = Workspaces.validate_lease(scope, lease.id, lock: true)
                 current
               end)

      assert {:ok, _} = Workspaces.release_lease(scope, lease.id, termination_evidence(lease))

      assert {:ok, _next} =
               Workspaces.admit_lease(scope, workspace.id, "next-turn", lease_deadline())

      assert {:error, :stale_generation} = Workspaces.validate_lease(scope, lease.id, lock: true)
    end

    test "organization colleagues cannot borrow an admitted execution actor's lease", %{
      scope: scope
    } do
      workspace = workspace_fixture(scope)
      assert {:ok, lease} = Workspaces.admit_lease(scope, workspace.id, "turn", lease_deadline())

      colleague =
        Hermitscale.AccountsFixtures.organization_scope_fixture(
          Hermitscale.AccountsFixtures.user_fixture(),
          scope.organization
        )

      colleague = put_in(colleague.membership.permissions, scope.membership.permissions)
      assert {:error, :lease_actor_mismatch} = Workspaces.validate_lease(colleague, lease.id)

      assert {:error, :lease_actor_mismatch} =
               Workspaces.write_file(colleague, workspace.id, lease.id, "file", "contents")

      assert {:error, :lease_actor_mismatch} =
               Workspaces.release_lease(colleague, lease.id, termination_evidence(lease))

      assert {:ok, ^lease} = Workspaces.validate_lease(scope, lease.id)
      refute_receive :management_termination_verified
    end

    test "remote allocation and termination revalidate revoked provider authority", %{
      scope: scope
    } do
      workspace = workspace_fixture(scope)
      assert {:ok, lease} = Workspaces.admit_lease(scope, workspace.id, "turn", lease_deadline())
      Hermitscale.WorkOSTest.Client.put_response(:list_memberships, {:ok, %{"data" => []}})

      assert {:error, :execution_actor_ineligible} =
               Workspaces.provision_workspace(scope, workspace.id)

      assert {:error, :execution_actor_ineligible} =
               Workspaces.release_lease(scope, lease.id, termination_evidence(lease))

      assert {:ok, retained} = Workspaces.get_workspace(scope, workspace.id)
      assert retained.id == workspace.id
      assert retained.resource_state == :provision_pending
      refute_receive {:management_allocate, _}
      refute_receive :management_termination_verified
    end

    test "retries reuse one lease and competing operations are rejected", %{scope: scope} do
      workspace = workspace_fixture(scope)
      deadline = lease_deadline()
      assert {:ok, lease} = Workspaces.admit_lease(scope, workspace.id, "turn-one", deadline)
      assert {:ok, ^lease} = Workspaces.admit_lease(scope, workspace.id, "turn-one", deadline)

      assert {:error, :lease_conflict} =
               Workspaces.admit_lease(scope, workspace.id, "turn-one", DateTime.add(deadline, 1))

      assert {:error, :workspace_busy} =
               Workspaces.admit_lease(scope, workspace.id, "turn-two", deadline)

      assert {:ok, ^lease} = Workspaces.validate_lease(scope, lease.id)
      assert {:error, :not_found} = Workspaces.validate_lease(workspace_scope_fixture(), lease.id)
      assert lease.execution_actor_user_id == scope.user.id
      assert {:ok, current} = Workspaces.get_workspace(scope, workspace.id)
      assert current.generation == lease.generation
    end

    test "termination evidence binds the operation and cannot free a writer before verification",
         %{scope: scope} do
      workspace = workspace_fixture(scope)

      assert {:ok, lease} =
               Workspaces.admit_lease(scope, workspace.id, "turn-one", lease_deadline())

      assert {:error, :termination_unverified} = Workspaces.release_lease(scope, lease.id, %{})
      evidence = termination_evidence(lease)

      assert {:error, :stale_generation} =
               Workspaces.release_lease(scope, lease.id, Map.put(evidence, "generation", 0))

      assert {:error, :termination_unverified} =
               Workspaces.release_lease(scope, lease.id, Map.put(evidence, "receipt", "forged"))

      assert {:ok, released} = Workspaces.release_lease(scope, lease.id, evidence)
      assert released.status == :released
      assert_receive :management_termination_verified
      assert {:ok, ^released} = Workspaces.release_lease(scope, lease.id, evidence)
      assert {:error, :lease_inactive} = Workspaces.validate_lease(scope, lease.id)

      assert {:ok, next} =
               Workspaces.admit_lease(scope, workspace.id, "turn-two", lease_deadline())

      assert next.generation == lease.generation + 1
      assert {:error, :stale_generation} = Workspaces.validate_lease(scope, lease.id)
      assert {:ok, _} = Workspaces.get_workspace(scope, workspace.id)
    end

    test "lease expiry does not release an unverified writer", %{scope: scope} do
      workspace = workspace_fixture(scope)

      assert {:error, :invalid_deadline} =
               Workspaces.admit_lease(
                 scope,
                 workspace.id,
                 "expired",
                 DateTime.add(DateTime.utc_now(), -1)
               )

      assert {:error, :invalid_deadline} =
               Workspaces.admit_lease(
                 scope,
                 workspace.id,
                 "unbounded",
                 DateTime.add(DateTime.utc_now(), 86_400)
               )

      assert {:ok, lease} =
               Workspaces.admit_lease(scope, workspace.id, "active", lease_deadline())

      lease
      |> Ecto.Changeset.change(deadline: DateTime.add(DateTime.utc_now(), -1))
      |> Repo.update!()

      assert {:error, :lease_expired} = Workspaces.validate_lease(scope, lease.id)

      assert {:error, :workspace_busy} =
               Workspaces.admit_lease(scope, workspace.id, "replacement", lease_deadline())
    end
  end

  describe "terminal retained lifecycle" do
    test "released hold retry cannot inspect or disturb a newer writer", %{scope: scope} do
      workspace = workspace_fixture(scope)
      {:ok, first} = Workspaces.admit_lease(scope, workspace.id, "first", lease_deadline())
      {:ok, released} = Workspaces.release_lease(scope, first.id, termination_evidence(first))
      assert_receive :management_termination_verified
      {:ok, next} = Workspaces.admit_lease(scope, workspace.id, "next", lease_deadline())

      assert {:ok, ^released} = Workspaces.release_activity(scope, first.id)
      assert_receive {:management_hold_released, id}
      assert id == first.id
      refute_receive {:management_evidence, _}
      refute_receive :management_termination_verified
      assert {:ok, ^next} = Workspaces.validate_lease(scope, next.id)
    end

    test "server revocation cleanup stops the admitted writer and retains storage", %{
      scope: scope
    } do
      workspace = workspace_fixture(scope)
      {:ok, lease} = Workspaces.admit_lease(scope, workspace.id, "revoked", lease_deadline())
      assert {:ok, released} = Workspaces.terminate_admitted(workspace.id, lease.id)
      assert released.status == :released
      assert_receive {:management_admitted_terminated, id}
      assert id == lease.id
      assert_receive {:management_hold_released, ^id}
      assert {:ok, current} = Workspaces.get_workspace(scope, workspace.id)
      assert current.resource_state != :deleted
      assert {:ok, ^released} = Workspaces.terminate_admitted(workspace.id, lease.id)
      assert_receive {:management_hold_released, ^id}
      other = workspace_fixture(scope)

      assert {:error, :lease_workspace_mismatch} =
               Workspaces.terminate_admitted(other.id, lease.id)
    end
  end

  describe "Shell and VFS policy" do
    test "live access requires the same current workspace writer and rejects unsafe paths", %{
      scope: scope
    } do
      workspace = workspace_fixture(scope)
      other = workspace_fixture(scope)
      assert {:ok, lease} = Workspaces.admit_lease(scope, workspace.id, "turn", lease_deadline())

      assert {:error, :lease_workspace_mismatch} =
               Workspaces.read_file(scope, other.id, lease.id, "lib/app.ex")

      assert {:error, :not_found} =
               Workspaces.write_file(
                 workspace_scope_fixture(),
                 workspace.id,
                 lease.id,
                 "lib/app.ex",
                 "text"
               )

      for path <- [
            "/etc/passwd",
            "../outside",
            "lib/../../outside",
            "lib\\outside",
            "lib//app.ex",
            <<0>>
          ] do
        assert {:error, :invalid_path} = Workspaces.read_file(scope, workspace.id, lease.id, path)
      end

      assert {:error, :restricted_path} =
               Workspaces.read_file(scope, workspace.id, lease.id, ".env")

      assert {:error, :file_too_large} =
               Workspaces.write_file(
                 scope,
                 workspace.id,
                 lease.id,
                 "large",
                 String.duplicate("x", 1_048_577)
               )

      assert {:error, :invalid_command} =
               Workspaces.execute_command(
                 scope,
                 workspace.id,
                 lease.id,
                 String.duplicate("x", 8193)
               )

      assert {:error, :sprites_token_missing} =
               Workspaces.read_file(scope, workspace.id, lease.id, "lib/app.ex")

      assert {:error, :sprites_token_missing} =
               Workspaces.write_file(scope, workspace.id, lease.id, "lib/app.ex", "text")

      assert {:error, :sprites_token_missing} =
               Workspaces.execute_command(scope, workspace.id, lease.id, "mix test")

      refute_receive {:management_allocate, _}
    end
  end
end
