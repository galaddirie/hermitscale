defmodule Hermitscale.Agents.PublishBranchTest do
  use Hermitscale.DataCase, async: false
  import Hermitscale.ProductFixtures
  import Hermitscale.AgentsFixtures
  import Hermitscale.IntegrationsFixtures
  alias Hermitscale.{Agents, AgentsRuntimeFake, Workspaces}
  alias Hermitscale.AuthTest.Provider
  alias Hermitscale.WorkOSTest.Client, as: Pipes

  setup do
    %{current_scope: scope} = authenticated_product_fixture()
    start_supervised!({Pipes, %{}})
    start_supervised!({AgentsRuntimeFake, []})
    configure_product_fixture(:workspace_management_adapter, AgentsRuntimeFake)
    configure_product_fixture(:workspace_access_adapter, AgentsRuntimeFake)

    Pipes.put_response(
      :list_org_providers,
      {:ok,
       %{
         "data" => [
           %{
             "slug" => "github",
             "connected_accounts" => [account_fixture("github", scope.organization.id)]
           }
         ]
       }}
    )

    Pipes.put_response(
      :vend_credentials,
      {:ok,
       %{auth_method: "oauth", value: "provider-secret", scopes: ["repo"], missing_scopes: []}}
    )

    %{
      scope: scope,
      session: agent_session_fixture(scope),
      request: %{
        branch: "feature/task",
        message: "Complete the task",
        operation_key: Ecto.UUID.generate()
      }
    }
  end

  test "explicit publishing returns Git evidence and retains only ordinary history", %{
    scope: scope,
    session: session,
    request: request
  } do
    assert {:ok, result} = Agents.publish_branch(scope, session.id, request)

    assert result == %{
             "repository" => session.repository,
             "branch" => request.branch,
             "commit_sha" => String.duplicate("b", 40)
           }

    assert {:ok, ^result} = Agents.publish_branch(scope, session.id, request)
    assert length(AgentsRuntimeFake.publications()) == 1

    assert [%{type: "branch.requested"}, %{type: "branch.published"}] =
             events = Agents.list_events(scope, session.id)

    refute Jason.encode!(Enum.map(events, & &1.payload)) =~ "provider-secret"
  end

  test "a changed branch request cannot reuse its key", %{
    scope: scope,
    session: session,
    request: request
  } do
    assert {:ok, _result} = Agents.publish_branch(scope, session.id, request)

    assert {:error, :publication_key_conflict} =
             Agents.publish_branch(scope, session.id, %{request | message: "Different intent"})

    assert length(AgentsRuntimeFake.publications()) == 1
  end

  test "current actor authority and private session ownership precede publishing", %{
    scope: scope,
    session: session,
    request: request
  } do
    denied = %{scope | membership: %{scope.membership | permissions: ["agents:read"]}}
    assert {:error, :forbidden} = Agents.publish_branch(denied, session.id, request)
    :ok = Provider.put_response(:get_role, {:ok, %{permissions: ["agents:read"]}})

    assert {:error, :execution_actor_ineligible} =
             Agents.publish_branch(scope, session.id, request)

    assert AgentsRuntimeFake.publications() == []
  end

  test "an existing coding writer excludes branch publication", %{
    scope: scope,
    session: session,
    request: request
  } do
    assert {:ok, _lease} =
             Workspaces.admit_lease(
               scope,
               session.workspace_id,
               "coding-task",
               DateTime.add(DateTime.utc_now(:second), 300)
             )

    assert {:error, :workspace_busy} = Agents.publish_branch(scope, session.id, request)
    assert AgentsRuntimeFake.publications() == []
  end
end
