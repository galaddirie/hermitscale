defmodule Hermitscale.Workspaces.SpriteAccessTest do
  use Hermitscale.DataCase, async: false
  alias Hermitscale.Workspaces
  alias Hermitscale.Workspaces.{SpriteAccess, SpritesManagement}
  import Hermitscale.WorkspacesFixtures

  setup do
    start_supervised!(Hermitscale.WorkOSTest.Client)
    prior_sdk = Application.get_env(:hermitscale, :sprites_sdk)
    prior_config = Application.get_env(:hermitscale, SpritesManagement)
    Application.put_env(:hermitscale, :sprites_sdk, Hermitscale.SpritesSDKFake)
    Application.put_env(:hermitscale, SpritesManagement, token: "host-only-fixture-token")

    on_exit(fn ->
      if prior_sdk,
        do: Application.put_env(:hermitscale, :sprites_sdk, prior_sdk),
        else: Application.delete_env(:hermitscale, :sprites_sdk)

      if prior_config,
        do: Application.put_env(:hermitscale, SpritesManagement, prior_config),
        else: Application.delete_env(:hermitscale, SpritesManagement)
    end)

    scope = workspace_scope_fixture()
    workspace = workspace_fixture(scope)
    {:ok, lease} = Workspaces.admit_lease(scope, workspace.id, "turn", lease_deadline())
    %{scope: scope, workspace: workspace, lease: lease}
  end

  test "real Jido Shell waits for remote exit and retains the Sprite on teardown", %{
    workspace: workspace,
    lease: lease
  } do
    start_supervised!(%{
      id: Hermitscale.SpritesSDKFake,
      start:
        {Agent, :start_link,
         [
           fn -> %{results: [["", 0], ["test output", 7]], calls: []} end,
           [name: Hermitscale.SpritesSDKFake]
         ]}
    })

    assert {:ok, %{exit_code: 7, output: "test output"}} =
             SpriteAccess.execute_command(workspace, lease, "mix test")

    calls = Hermitscale.SpritesSDKFake.calls()
    assert length(calls) == 2
    assert Enum.all?(calls, fn {name, _cmd, _args, _opts} -> name == workspace.sprite_name end)
    assert {_name, "sh", ["-lc", line], _opts} = List.last(calls)
    assert String.contains?(line, "sandbox-launch coder")
    assert String.contains?(line, "timeout --signal=TERM --kill-after=2s")
  end

  test "real Jido VFS transports bounded nofollow file operations using server-owned identity", %{
    scope: scope,
    workspace: workspace,
    lease: lease
  } do
    start_supervised!(%{
      id: Hermitscale.SpritesSDKFake,
      start:
        {Agent, :start_link,
         [
           fn -> %{results: [["", 0], [Base.encode64("retained content"), 0]], calls: []} end,
           [name: Hermitscale.SpritesSDKFake]
         ]}
    })

    assert {:ok, "retained content"} =
             Workspaces.read_file(scope, workspace.id, lease.id, "lib/app.ex")

    assert {_name, "sudo", ["-n", "python3", "-I", "-c", script, "read", "/workspace/lib/app.ex"],
            _opts} = List.last(Hermitscale.SpritesSDKFake.calls())

    assert String.contains?(script, "os.O_NOFOLLOW")
    assert String.contains?(script, "1048576")

    assert {:error, :not_found} =
             Workspaces.read_file(workspace_scope_fixture(), workspace.id, lease.id, "lib/app.ex")

    assert {:error, :invalid_path} =
             Workspaces.read_file(scope, workspace.id, lease.id, "../secret")

    assert length(Hermitscale.SpritesSDKFake.calls()) == 2
  end

  test "writer completion allows evidence after deadline while a newer generation stays fenced",
       %{scope: scope, workspace: workspace, lease: lease} do
    expired =
      lease
      |> Ecto.Changeset.change(deadline: DateTime.add(DateTime.utc_now(), -1))
      |> Repo.update!()

    assert {:error, :lease_expired} = Workspaces.validate_lease(scope, expired.id)

    assert {:ok, ^expired} =
             Workspaces.validate_lease(scope, expired.id, purpose: :evidence, lock: true)

    Repo.update!(Ecto.Changeset.change(workspace, generation: lease.generation + 1))

    assert {:error, :stale_generation} =
             Workspaces.validate_lease(scope, expired.id, purpose: :evidence)
  end
end
