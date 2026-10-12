defmodule Hermitscale.Workflows.CredentialsTest do
  use ExUnit.Case, async: false
  import Hermitscale.AccountsFixtures
  import Hermitscale.WorkflowsFixtures
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Workflows.{Compiler, Credentials, Validator}
  alias Hermitscale.WorkOSTest.Client

  setup do
    start_supervised!({Client, %{}})
    %{scope: user_scope_fixture(), graph: credential_probe_graph()}
  end

  describe "canonical selections" do
    test "two permitted members receive the same account and their own actor", %{
      scope: scope,
      graph: graph
    } do
      {:ok, workflow} = Compiler.compile(graph)
      collaborator = organization_scope_fixture(user_fixture(), scope.organization)

      for member <- [scope, collaborator] do
        assert {:ok, %{"probe" => %{credentials: ref}}} =
                 Credentials.resolve_run_context(
                   graph,
                   workflow,
                   %{},
                   Scope.execution_context(member)
                 )

        assert ref.account_id == "data_test"
        assert ref.execution_context.actor_user_id == member.user.id
        assert ref.execution_context.organization_id == scope.organization.id
        refute Map.has_key?(Map.from_struct(ref), :value)
      end

      refute Enum.any?(Client.calls(), fn {op, _} -> op == :vend_credentials end)
    end

    test "rejects all former binding formats and forged selection authority", %{graph: graph} do
      for legacy <- [
            Map.put(graph, "credentials", %{}),
            put_in(graph["nodes"], [Map.put(hd(graph["nodes"]), "credentials", %{})]),
            put_in(graph["nodes"], [
              put_in(hd(graph["nodes"])["connection"]["actor_user_id"], "user_victim")
            ])
          ] do
        assert {:error, _issues} = Validator.validate(legacy)
      end
    end

    test "missing selections and foreign organization accounts fail before execution", %{
      scope: scope,
      graph: graph
    } do
      missing = update_in(graph["nodes"], &Enum.map(&1, fn n -> Map.delete(n, "connection") end))
      {:ok, workflow} = Compiler.compile(missing)

      assert {:error, {:connection_setup_required, "probe"}} =
               Credentials.resolve_run_context(
                 missing,
                 workflow,
                 %{},
                 Scope.execution_context(scope)
               )

      Client.put_response(:list_org_providers, {:ok, %{"data" => []}})

      assert {:error, {:connection_not_ready, "probe", :account_not_found}} =
               Credentials.readiness(graph, Scope.execution_context(scope))
    end

    test "runtime context cannot inject credentials or execution authority", %{
      scope: scope,
      graph: graph
    } do
      {:ok, workflow} = Compiler.compile(graph)

      for context <- [
            %{credentials: "secret"},
            %{"probe" => %{credentials: %{value: "secret"}}},
            %{actor_user_id: "user_victim"},
            %{env: %{execution_context: %{user_id: "user_victim"}}}
          ] do
        assert {:error, :reserved_run_context} =
                 Credentials.resolve_run_context(
                   graph,
                   workflow,
                   context,
                   Scope.execution_context(scope)
                 )
      end
    end

    test "a persisted selection stays stable when another account is added", %{
      scope: scope,
      graph: graph
    } do
      Client.put_response(:list_org_providers, {:ok, %{"data" => []}})
      assert {:ok, ^graph} = Credentials.select_accounts(scope, graph)
    end

    test "requirements come from catalog operation metadata", %{graph: graph} do
      assert [%{provider: "test.credentials", scopes: ["scope:a"], nodes: ["probe"]}] =
               Credentials.requirements(graph)
    end

    test "selection and requirement collection preserve graph node order", %{
      scope: scope,
      graph: graph
    } do
      [node] = graph["nodes"]

      graph =
        Map.put(graph, "nodes", [
          node,
          Map.put(node, "id", "second"),
          Map.put(node, "id", "third")
        ])

      assert {:ok, ^graph} = Credentials.select_accounts(scope, graph)
      assert [%{nodes: ["probe", "second", "third"]}] = Credentials.requirements(graph)
    end
  end
end
