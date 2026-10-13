defmodule Hermitscale.Workflows.GraphAdmissionTest do
  use Hermitscale.DataCase, async: false
  import Hermitscale.ProductFixtures
  import Hermitscale.WorkflowsFixtures
  import Hermitscale.IntegrationsFixtures
  alias Hermitscale.{Workflows, AuthTest.Provider}
  alias Hermitscale.Workflows.{Graph, Run}
  alias Hermitscale.WorkOSTest.Client, as: Pipes

  setup do
    %{current_scope: scope} = authenticated_product_fixture()
    start_supervised!({Pipes, %{}})
    %{scope: scope}
  end

  test "a creation key binds raw authoring intent before automatic provider selection", %{
    scope: scope
  } do
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

    definition =
      valid_join_graph(%{
        "nodes" => [
          %{
            "id" => "issue",
            "type" => "github.issues.get",
            "version" => 1,
            "params" => %{"owner" => "acme", "repo" => "backend", "issue_number" => 7}
          }
        ],
        "connections" => []
      })

    attrs =
      graph_attrs(%{
        id: "wf_explicit_caller_id",
        definition: definition,
        operation_key: Ecto.UUID.generate()
      })

    assert {:ok, graph} = Workflows.create_graph(scope, attrs)
    assert graph.id == attrs.id
    assert graph.operation_key == attrs.operation_key
    assert graph.admission_digest != nil

    assert hd(graph.definition["nodes"])["connection"] == %{
             "provider" => "github",
             "account_id" => "data_github"
           }

    calls = Pipes.calls()
    Pipes.put_response(:list_org_providers, {:error, :unavailable})
    assert {:ok, ^graph} = Workflows.create_graph(scope, attrs)
    assert Pipes.calls() == calls
    assert Repo.aggregate(Graph, :count) == 1

    assert {:error, :operation_key_conflict} =
             Workflows.create_graph(scope, %{attrs | name: "Changed name"})

    assert {:error, :operation_key_conflict} =
             Workflows.create_graph(scope, %{attrs | id: "wf_changed_id"})
  end

  test "operation identity belongs to both actor and organization", %{scope: scope} do
    key = Ecto.UUID.generate()
    attrs = graph_attrs(%{id: "wf_owner", operation_key: key})
    assert {:ok, first} = Workflows.create_graph(scope, attrs)
    {:ok, member} = Provider.update_membership("membership:colleague", "admin")

    colleague =
      Hermitscale.Accounts.Scope.for_user(%{id: "colleague"})
      |> Hermitscale.Accounts.Scope.put_organization(
        scope.organization,
        Map.put(
          member,
          :permissions,
          Hermitscale.AccountsFixtures.role_permissions_fixture("admin")
        )
      )

    assert {:ok, second} = Workflows.create_graph(colleague, %{attrs | id: "wf_colleague"})
    assert second.created_by_user_id == "colleague"
    assert second.id != first.id
    other = Hermitscale.AccountsFixtures.organization_scope_fixture()
    assert {:ok, third} = Workflows.create_graph(other, %{attrs | id: "wf_other_org"})
    assert third.org_id == other.organization.id
    assert third.id not in [first.id, second.id]
  end

  test "keys are typed and updates cannot replace immutable creation identity", %{scope: scope} do
    attrs = graph_attrs(%{id: "wf_keys", operation_key: Ecto.UUID.generate()})

    for key <- [nil, 1, "short", String.duplicate("k", 129)] do
      assert {:error, :invalid_operation_key} =
               Workflows.create_graph(scope, %{attrs | operation_key: key})
    end

    assert {:ok, graph} = Workflows.create_graph(scope, attrs)

    assert {:ok, edited} =
             Workflows.update_graph(scope, graph, %{
               name: "Edited title",
               operation_key: "replacement-key",
               admission_digest: "invented"
             })

    assert edited.operation_key == graph.operation_key
    assert edited.admission_digest == graph.admission_digest
    assert {:ok, same} = Workflows.create_graph(scope, attrs)
    assert same.id == edited.id
    assert same.name == "Edited title"
  end

  test "draft authors cannot activate graphs without activation permission", %{scope: scope} do
    author = %{scope | membership: %{scope.membership | permissions: ["workflows:edit"]}}
    attrs = graph_attrs(%{id: "wf_activation", status: :draft})
    assert {:error, :forbidden} = Workflows.create_graph(author, %{attrs | status: :active})
    assert {:ok, draft} = Workflows.create_graph(author, attrs)
    assert {:error, :forbidden} = Workflows.update_graph(author, draft, %{status: :active})
    assert Workflows.get_graph!(scope, draft.id).status == :draft
    assert {:ok, active} = Workflows.update_graph(scope, draft, %{status: :active})
    assert {:ok, edited} = Workflows.update_graph(author, active, %{name: "Still active"})
    assert edited.status == :active
  end

  test "stored run lists are bounded and isolate graph, tenant and permission", %{scope: scope} do
    first = product_graph_fixture(scope)
    second = product_graph_fixture(scope)
    assert {:ok, other_run} = Workflows.create_run(scope, second)
    now = DateTime.utc_now(:second)

    runs =
      for index <- 1..101,
          do: %{
            id: "stored-run-#{index}",
            workflow_graph_id: first.id,
            definition: first.definition,
            status: :created,
            inserted_at: now,
            updated_at: now
          }

    assert {101, nil} = Repo.insert_all(Run, runs)
    stored = Workflows.list_runs(scope, first.id)
    assert length(stored) == 100
    assert Enum.all?(stored, &(&1.workflow_graph_id == first.id))
    assert [^other_run] = Workflows.list_runs(scope, second.id)
    foreign = Hermitscale.AccountsFixtures.organization_scope_fixture()
    assert [] = Workflows.list_runs(foreign, first.id)
    denied = %{scope | membership: %{scope.membership | permissions: []}}
    assert {:error, :forbidden} = Workflows.list_runs(denied, first.id)
    assert Workflows.list_runs(scope, "unknown-graph") == []
  end
end
