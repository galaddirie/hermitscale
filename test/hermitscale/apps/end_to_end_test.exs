defmodule Hermitscale.Apps.EndToEndTest do
  use Hermitscale.DataCase, async: false
  import Hermitscale.AppsFixtures
  import Hermitscale.ProductFixtures
  alias Hermitscale.{Agents, Apps, AppsRuntimeFake, Workspaces}
  alias Hermitscale.AuthTest.Provider

  setup do
    %{current_scope: scope} = authenticated_product_fixture()
    start_supervised!({AppsRuntimeFake, []})
    configure_product_fixture(:workspace_management_adapter, AppsRuntimeFake)
    configure_product_fixture(:workspace_access_adapter, AppsRuntimeFake)
    %{scope: scope}
  end

  test "one app reuses one owner conversation without allocating compute", %{scope: scope} do
    app = app_fixture(scope)
    assert {:ok, first} = Apps.start_build(scope, app.id, %{})
    assert {:ok, second} = Apps.start_build(scope, app.id, %{})
    assert second.id == first.id
    assert [session] = Agents.list_sessions(scope)
    assert session.id == first.id
    assert {:ok, current} = Apps.get_app(scope, app.id)
    assert current.session_id == first.id
    assert {:ok, workspace} = Apps.workspace(scope, app.id)
    assert workspace.id == first.workspace_id
    assert workspace.resource_state == :provision_pending
    assert AppsRuntimeFake.calls() == []

    assert {:ok, turn} =
             Agents.submit_turn(scope, first.id, %{
               instructions: "Build a useful app",
               operation_key: Ecto.UUID.generate()
             })

    assert turn.session_id == first.id
    assert AppsRuntimeFake.calls() == []
  end

  test "app creation is idempotent and organization readers cannot edit another actor's app", %{
    scope: scope
  } do
    attrs = %{name: "Team app", slug: "team-app", operation_key: Ecto.UUID.generate()}
    assert {:ok, app} = Apps.create_app(scope, attrs)
    assert {:ok, same} = Apps.create_app(scope, attrs)
    assert same.id == app.id

    assert {:error, :operation_key_conflict} =
             Apps.create_app(scope, %{attrs | name: "Another app"})

    assert {:ok, _membership} = Provider.update_membership("membership:colleague", "admin")
    colleague = colleague_app_scope_fixture(scope)
    assert {:ok, readable} = Apps.get_app(colleague, app.id)
    assert readable.id == app.id
    assert {:error, :forbidden} = Apps.start_build(colleague, app.id, %{})
    assert {:error, :forbidden} = Apps.ensure_preview(colleague, app.id, service_attrs_fixture())
    assert {:error, :forbidden} = Apps.workspace(colleague, app.id)
    assert {:error, :not_found} = Apps.get_app(app_scope_fixture(), app.id)

    denied = %{scope | membership: %{scope.membership | permissions: []}}
    assert {:error, :forbidden} = Apps.get_app(denied, app.id)
    assert {:error, :forbidden} = Apps.create_app(denied, attrs)
    assert AppsRuntimeFake.calls() == []
  end

  test "private start, explicit public publication, native logs and stop use the same Sprite", %{
    scope: scope
  } do
    app = app_fixture(scope)
    session = app_build_fixture(scope, app)
    attrs = service_attrs_fixture(%{start_command: "npm run start", port: 3000})
    assert {:ok, preview} = Apps.ensure_preview(scope, app.id, attrs)
    refute preview.public
    assert preview.service_status == "running"
    assert preview.native_url == "https://#{session.workspace_id}.sprites.app"
    assert preview.source_commit == String.duplicate("a", 40)
    assert preview.start_command == attrs.start_command

    assert {:start_service, workspace_id, "hs-app", spec} =
             Enum.find(AppsRuntimeFake.calls(), &match?({:start_service, _, _, _}, &1))

    assert workspace_id == session.workspace_id
    assert "npm run start" in spec.args
    assert spec.http_port == 3000
    refute Enum.any?(AppsRuntimeFake.calls(), &match?({:access, _, :public}, &1))

    assert {:ok, published} = Apps.publish(scope, app.id, %{})
    assert published.public
    assert published.session_id == session.id
    assert {:access, session.workspace_id, :public} in AppsRuntimeFake.calls()
    assert {:ok, "App started\n"} = Apps.read_logs(scope, app.id, limit: 20)
    assert {:logs, session.workspace_id, 20} in AppsRuntimeFake.calls()
    assert {:ok, stopped} = Apps.stop(scope, app.id)
    assert stopped.service_status == "stopped"
    refute stopped.public
    assert {:stop_service, session.workspace_id, "hs-app"} in AppsRuntimeFake.calls()
    assert {:ok, workspace} = Workspaces.get_workspace(scope, session.workspace_id)
    assert workspace.resource_state == :retained
  end

  test "invalid commands, unattached conversations and revoked authority start no service", %{
    scope: scope
  } do
    app = app_fixture(scope)

    assert {:error, :conversation_required} =
             Apps.ensure_preview(scope, app.id, service_attrs_fixture())

    session = app_build_fixture(scope, app)

    assert {:error, %Ecto.Changeset{}} =
             Apps.ensure_preview(scope, app.id, %{start_command: "", port: 3000})

    assert {:error, %Ecto.Changeset{}} =
             Apps.ensure_preview(scope, app.id, service_attrs_fixture(%{port: 0}))

    assert session.id != nil
    assert AppsRuntimeFake.calls() == []

    Provider.put_response(:get_role, {:ok, %{slug: "reader", permissions: ["apps:read"]}})

    assert {:error, :execution_actor_ineligible} =
             Apps.ensure_preview(scope, app.id, service_attrs_fixture())

    assert {:error, :execution_actor_ineligible} =
             Apps.publish(scope, app.id, service_attrs_fixture())

    assert AppsRuntimeFake.calls() == []
  end

  test "native visibility needs no release proof and service permissions do not grant history access",
       %{scope: scope} do
    app = app_fixture(scope)
    _session = app_build_fixture(scope, app)
    AppsRuntimeFake.no_commit()
    operator = %{scope | membership: %{scope.membership | permissions: ["apps:write"]}}
    Provider.put_response(:get_role, {:ok, %{slug: "operator", permissions: ["apps:write"]}})

    assert {:ok, preview} = Apps.ensure_preview(operator, app.id, service_attrs_fixture())
    assert preview.source_commit == nil
    refute preview.public
    assert {:error, :forbidden} = Agents.get_session(operator, preview.session_id)
    assert {:error, :forbidden} = Apps.publish(operator, app.id, %{})

    AppsRuntimeFake.clear_calls()
    reader = %{scope | membership: %{scope.membership | permissions: ["apps:read"]}}
    assert {:ok, _workspace} = Apps.workspace(reader, app.id)
    assert AppsRuntimeFake.calls() == []

    Provider.reset_responses()
    assert {:ok, public} = Apps.publish(scope, app.id, %{})
    assert public.public
    assert public.source_commit == nil
  end
end
