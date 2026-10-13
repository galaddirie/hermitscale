defmodule Hermitscale.Workspaces.SpritesManagementTest do
  use Hermitscale.DataCase, async: false
  import Hermitscale.WorkspacesFixtures
  alias Hermitscale.Workspaces
  alias Hermitscale.Workspaces.SpritesManagement

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    start_supervised!(Hermitscale.WorkOSTest.Client)
    prior_adapter = Application.get_env(:hermitscale, :workspace_management_adapter)
    prior_config = Application.get_env(:hermitscale, SpritesManagement)
    Application.put_env(:hermitscale, :workspace_management_adapter, SpritesManagement)

    Application.put_env(:hermitscale, SpritesManagement,
      token: "server-fleet-secret",
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn ->
      restore(:workspace_management_adapter, prior_adapter)
      restore(SpritesManagement, prior_config)
    end)

    scope = workspace_scope_fixture()
    %{scope: scope, workspace: workspace_fixture(scope)}
  end

  test "creates private storage only after inspecting the durable name", %{
    scope: scope,
    workspace: workspace
  } do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/sprites/" <> workspace.sprite_name
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer server-fleet-secret"]
      Plug.Conn.send_resp(conn, 404, "missing")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/sprites"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "name" => workspace.sprite_name,
               "url_settings" => %{"auth" => "sprite"}
             }

      conn |> Plug.Conn.put_status(201) |> Req.Test.json(metadata(workspace))
    end)

    assert {:ok, retained} = Workspaces.provision_workspace(scope, workspace.id)
    assert retained.resource_state == :retained
    assert retained.compute_state == :sleeping
  end

  test "lost create response reconciles the same resource instead of repeating creation", %{
    scope: scope,
    workspace: workspace
  } do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 404, "missing") end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      Plug.Conn.send_resp(conn, 503, "response lost")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, metadata(workspace))
    end)

    assert {:ok, retained} = Workspaces.provision_workspace(scope, workspace.id)
    assert retained.sprite_name == workspace.sprite_name
  end

  test "uncertain creation remains pending until another bounded reconciliation", %{
    scope: scope,
    workspace: workspace
  } do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 404, "missing") end)
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "uncertain") end)
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 404, "missing") end)
    assert {:error, :allocation_uncertain} = Workspaces.provision_workspace(scope, workspace.id)
    assert {:ok, pending} = Workspaces.get_workspace(scope, workspace.id)
    assert pending.resource_state == :provision_pending
  end

  test "rejects redirects and mismatched resource metadata", %{scope: scope, workspace: workspace} do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://other.example")
      |> Plug.Conn.send_resp(302, "redirect")
    end)

    assert {:error, :redirect_not_allowed} = Workspaces.provision_workspace(scope, workspace.id)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, Map.put(metadata(workspace), "name", "wrong"))
    end)

    assert {:error, :invalid_provider_response} =
             Workspaces.provision_workspace(scope, workspace.id)
  end

  test "missing configuration remains disabled and allocation cannot verify writers", %{
    scope: scope,
    workspace: workspace
  } do
    Application.delete_env(:hermitscale, SpritesManagement)
    assert {:error, :sprites_token_missing} = Workspaces.provision_workspace(scope, workspace.id)
    assert {:ok, lease} = Workspaces.admit_lease(scope, workspace.id, "turn", lease_deadline())

    assert {:error, :sprites_token_missing} =
             Workspaces.release_lease(scope, lease.id, termination_evidence(lease))
  end

  test "service visibility uses the native public and sprite authentication settings", %{
    workspace: workspace
  } do
    for {access, auth} <- [public: "public", private: "sprite"] do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/v1/sprites/" <> workspace.sprite_name
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"url_settings" => %{"auth" => auth}}
        Req.Test.json(conn, metadata(workspace))
      end)

      assert :ok = SpritesManagement.set_app_access(workspace, access)
    end
  end

  test "native app URL accepts either visibility and rejects unrelated hosts", %{
    workspace: workspace
  } do
    for auth <- ["public", "sprite"] do
      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(
          conn,
          Map.merge(metadata(workspace), %{
            "url" => "https://#{workspace.sprite_name}-org.sprites.app",
            "url_settings" => %{"auth" => auth}
          })
        )
      end)

      assert {:ok, "https://" <> _rest} = SpritesManagement.app_url(workspace)
    end

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, Map.put(metadata(workspace), "url", "https://unrelated.example"))
    end)

    assert {:error, :invalid_app_upstream} = SpritesManagement.app_url(workspace)
  end

  defp metadata(workspace),
    do: %{
      "name" => workspace.sprite_name,
      "status" => "cold",
      "url_settings" => %{"auth" => "sprite"}
    }

  defp restore(key, nil), do: Application.delete_env(:hermitscale, key)
  defp restore(key, value), do: Application.put_env(:hermitscale, key, value)
end
