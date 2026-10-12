defmodule Hermitscale.Integrations.ExpandedActionsTest do
  use ExUnit.Case, async: false
  alias Hermitscale.Integrations.{GitHub, Linear}
  alias Hermitscale.WorkOSTest.Client, as: Pipes
  import Hermitscale.IntegrationsFixtures
  import Hermitscale.WorkflowsFixtures, only: [credential_reference_fixture: 2]

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    start_supervised!(Pipes)

    Pipes.put_response(:list_org_providers, fn org ->
      accounts =
        for provider <- ~w(github linear),
            do: %{"slug" => provider, "connected_accounts" => [account_fixture(provider, org)]}

      {:ok, %{"data" => accounts}}
    end)

    Pipes.put_response(:vend_credentials, fn provider, _user, _org, _id ->
      {:ok,
       %{
         auth_method: "oauth",
         value: "provider-secret",
         scopes: scopes_fixture(provider),
         missing_scopes: []
       }}
    end)

    %{opts: [plug: {Req.Test, __MODULE__}]}
  end

  describe "GitHub actions" do
    test "a limit crossing a page boundary preserves the same page size", %{opts: opts} do
      Req.Test.expect(__MODULE__, fn conn ->
        assert URI.decode_query(conn.query_string)["per_page"] == "100"

        conn
        |> Plug.Conn.put_resp_header(
          "link",
          "<https://api.github.com/issues?page=2>; rel=\"next\""
        )
        |> Req.Test.json(Enum.map(1..100, &%{"id" => &1}))
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert URI.decode_query(conn.query_string) == %{"page" => "2", "per_page" => "100"}
        Req.Test.json(conn, Enum.map(101..200, &%{"id" => &1}))
      end)

      assert {:ok, items} =
               GitHub.Operations.execute(
                 :users_get_issues,
                 %{return_all: false, limit: 150, filters: %{}},
                 ref("github"),
                 opts
               )

      assert Enum.map(items, & &1["id"]) == Enum.to_list(1..150)
    end

    test "normalized repo and admin:org consent satisfies implied webhook and organization scopes" do
      alias Hermitscale.Integrations.{ConnectedAccounts, ExecutionContext}

      Pipes.put_response(:list_org_providers, fn org ->
        account = account_fixture("github", org) |> Map.put("scopes", ["repo", "admin:org"])
        {:ok, %{"data" => [%{"slug" => "github", "connected_accounts" => [account]}]}}
      end)

      Pipes.put_response(
        :vend_credentials,
        {:ok,
         %{
           auth_method: "oauth",
           value: "provider-secret",
           scopes: ["repo", "admin:org"],
           missing_scopes: []
         }}
      )

      context = %ExecutionContext{
        organization_id: "org_test",
        actor_user_id: "user_test",
        required_permissions: ["workflows:run"]
      }

      assert {:ok, credential} =
               ConnectedAccounts.credential_ref(
                 context,
                 %{"provider" => "github", "account_id" => "data_github"},
                 ["admin:repo_hook", "read:org"]
               )

      assert {:ok, _} = ConnectedAccounts.vend(credential)

      refute Hermitscale.Integrations.Provider.scopes_satisfied?(
               GitHub.descriptor(),
               ["read:org", "read:repo_hook"],
               ["repo", "admin:org"]
             )
    end

    test "edits a file using its branch-specific SHA and explicit text encoding", %{opts: opts} do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/repos/acme/backend/contents/docs/readme.md"
        assert URI.decode_query(conn.query_string)["ref"] == "feature/one"
        Req.Test.json(conn, %{"sha" => "old-sha"})
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "PUT"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(raw) == %{
                 "content" => Base.encode64("hello"),
                 "message" => "Update",
                 "branch" => "feature/one",
                 "sha" => "old-sha"
               }

        Req.Test.json(conn, %{"commit" => %{"sha" => "new-sha"}})
      end)

      assert {:ok, %{"commit" => _}} =
               GitHub.Operations.execute(
                 :files_edit,
                 %{
                   owner: "acme",
                   repo: "backend",
                   path: "docs/readme.md",
                   content: "hello",
                   message: "Update",
                   encoding: "text",
                   fields: %{"branch" => "feature/one"}
                 },
                 ref("github"),
                 opts
               )
    end

    test "paginates using the fixed API destination and preserves collection order", %{opts: opts} do
      Req.Test.expect(__MODULE__, fn conn ->
        assert URI.decode_query(conn.query_string)["page"] == "1"

        conn
        |> Plug.Conn.put_resp_header(
          "link",
          "<https://api.github.com/repos/acme/backend/issues?page=2>; rel=\"next\""
        )
        |> Req.Test.json([%{"id" => 1}])
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.host == "api.github.com"
        assert URI.decode_query(conn.query_string)["page"] == "2"
        Req.Test.json(conn, [%{"id" => 2}])
      end)

      assert {:ok, [%{"id" => 1}, %{"id" => 2}]} =
               GitHub.Operations.execute(
                 :repositories_get_issues,
                 %{owner: "acme", repo: "backend", return_all: true, limit: 50, filters: %{}},
                 ref("github"),
                 opts
               )
    end

    test "mutation requests do not retry and no-content results remain JSON data", %{opts: opts} do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "PUT"
        Plug.Conn.send_resp(conn, 204, "")
      end)

      params = %{owner: "acme", repo: "backend", workflow_id: "ci.yml"}

      assert {:ok, %{"success" => true}} =
               GitHub.Operations.execute(:workflows_disable, params, ref("github"), opts)

      Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "private failure") end)

      assert {:error, {:provider_request_failed, 503}} =
               GitHub.Operations.execute(:workflows_disable, params, ref("github"), opts)
    end

    test "diff and patch use media headers without following download redirects", %{opts: opts} do
      Req.Test.expect(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "accept") == ["application/vnd.github.diff"]
        Plug.Conn.send_resp(conn, 200, "diff --git a/file b/file")
      end)

      assert {:ok, %{"diff" => "diff --git a/file b/file"}} =
               GitHub.Operations.execute(
                 :pull_requests_get_diff,
                 %{owner: "acme", repo: "backend", pull_number: 7},
                 ref("github"),
                 opts
               )
    end
  end

  describe "Linear actions" do
    test "uses variables for update, delete, comment and link mutations", %{opts: opts} do
      for {operation, params, mutation, resource} <- [
            {:issues_update, %{issue_id: "ENG-7", fields: %{"priority" => 1}}, "issueUpdate",
             "issue"},
            {:issues_delete, %{issue_id: "ENG-7"}, "issueDelete", nil},
            {:comments_create, %{issue_id: "issue-id", body: "A comment"}, "commentCreate",
             "comment"},
            {:issues_add_link,
             %{issue_id: "issue-id", title: "Link", url: "https://example.test/report"},
             "attachmentCreate", "attachment"}
          ] do
        Req.Test.expect(__MODULE__, fn conn ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(raw)
          assert decoded["query"] =~ mutation
          assert is_map(decoded["variables"])

          response =
            if resource,
              do: %{"success" => true, resource => %{"id" => "result-id"}},
              else: %{"success" => true}

          Req.Test.json(conn, %{"data" => %{mutation => response}})
        end)

        assert {:ok, _result} = Linear.Operations.execute(operation, params, ref("linear"), opts)
      end
    end

    test "issues pagination forwards filters and rejects a repeated cursor", %{opts: opts} do
      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        vars = Jason.decode!(raw)["variables"]
        assert vars["filter"] == %{"team" => %{"id" => %{"eq" => "team-id"}}}

        Req.Test.json(conn, %{
          "data" => %{
            "issues" => %{
              "nodes" => [%{"id" => "one"}],
              "pageInfo" => %{"hasNextPage" => true, "endCursor" => "same"}
            }
          }
        })
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issues" => %{
              "nodes" => [%{"id" => "two"}],
              "pageInfo" => %{"hasNextPage" => true, "endCursor" => "same"}
            }
          }
        })
      end)

      assert {:error, :invalid_pagination} =
               Linear.Operations.execute(
                 :issues_list,
                 %{
                   return_all: true,
                   limit: 50,
                   filter: %{"team" => %{"id" => %{"eq" => "team-id"}}},
                   include_archived: false
                 },
                 ref("linear"),
                 opts
               )
    end
  end

  describe "catalog parity" do
    test "all Linear nodes accept provider JSON fields and execute through compiled graphs" do
      alias Hermitscale.Workflows.{Compiler, Credentials, Engine}
      previous = Application.get_env(:hermitscale, Linear.Client)

      Application.put_env(:hermitscale, Linear.Client,
        req_options: [plug: {Req.Test, __MODULE__}]
      )

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:hermitscale, Linear.Client),
          else: Application.put_env(:hermitscale, Linear.Client, previous)
      end)

      params = %{
        "issue_id" => "HER-1",
        "team_id" => "team-1",
        "title" => "Title",
        "description" => "Description",
        "fields" => %{"priority" => 1},
        "body" => "Comment",
        "url" => "https://example.test",
        "filter" => %{"team" => %{"id" => %{"eq" => "team-1"}}}
      }

      issue = %{"id" => "issue-1", "identifier" => "HER-1", "title" => "Title"}

      for {operation, field, resource} <- [
            {:issues_get, "issue", nil},
            {:issues_create, "issueCreate", "issue"},
            {:issues_update, "issueUpdate", "issue"},
            {:issues_delete, "issueDelete", nil},
            {:issues_list, "issues", nil},
            {:comments_create, "commentCreate", "comment"},
            {:issues_add_link, "attachmentCreate", "attachment"}
          ] do
        definition = Map.fetch!(Linear.Operations.definitions(), operation)
        selected = Map.take(params, Enum.map(Keyword.keys(definition.params), &Atom.to_string/1))

        graph = %{
          "schema_version" => 1,
          "id" => "wf_linear_action",
          "name" => "action",
          "nodes" => [
            %{
              "id" => "action",
              "type" => definition.id,
              "version" => 1,
              "params" => selected,
              "connection" => %{"provider" => "linear", "account_id" => "data_linear"}
            }
          ],
          "connections" => []
        }

        Req.Test.expect(__MODULE__, fn conn ->
          assert conn.method == "POST"
          assert conn.request_path == "/graphql"
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          request = Jason.decode!(raw)
          assert request["query"] =~ field
          assert is_map(request["variables"])

          result =
            case operation do
              :issues_get ->
                issue

              :issues_list ->
                %{"nodes" => [issue], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}

              :issues_delete ->
                %{"success" => true}

              _ ->
                %{"success" => true, resource => issue}
            end

          Req.Test.json(conn, %{"data" => %{field => result}})
        end)

        assert {:ok, workflow} = Compiler.compile(graph)

        assert {:ok, context} =
                 Credentials.resolve_run_context(
                   graph,
                   workflow,
                   %{},
                   execution_context_fixture()
                 )

        executed =
          workflow
          |> Runic.Workflow.put_run_context(context)
          |> Runic.Workflow.react_until_satisfied(%{})

        assert :ok = Engine.completion(executed)
        assert [_result] = Engine.productions(executed, "action")
      end
    end

    test "every GitHub catalog action executes the expected REST operation through a compiled graph",
         %{opts: _opts} do
      alias Hermitscale.Workflows.{Catalog, Compiler, Credentials, Engine}
      previous = Application.get_env(:hermitscale, GitHub.Client)

      Application.put_env(:hermitscale, GitHub.Client,
        req_options: [plug: {Req.Test, __MODULE__}]
      )

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:hermitscale, GitHub.Client),
          else: Application.put_env(:hermitscale, GitHub.Client, previous)
      end)

      for {operation, method, path} <- Hermitscale.GitHubActionsFixtures.requests_fixture() do
        definition = Map.fetch!(GitHub.Operations.definitions(), operation)

        raw_params =
          Hermitscale.GitHubActionsFixtures.params_fixture()
          |> Map.take(Keyword.keys(definition.params))

        raw_params =
          if operation in [:files_edit, :files_delete],
            do: Map.put(raw_params, :fields, %{"sha" => "known-sha"}),
            else: raw_params

        raw_params =
          if operation == :files_list, do: Map.put(raw_params, :path, "docs"), else: raw_params

        params = Map.new(raw_params, fn {k, v} -> {Atom.to_string(k), v} end)

        graph = %{
          "schema_version" => 1,
          "id" => "wf_action",
          "name" => "action",
          "nodes" => [
            %{
              "id" => "action",
              "type" => definition.id,
              "version" => 1,
              "params" => params,
              "connection" => %{"provider" => "github", "account_id" => "data_github"}
            }
          ],
          "connections" => []
        }

        Req.Test.expect(__MODULE__, fn conn ->
          assert conn.method == method
          assert conn.request_path == path
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer provider-secret"]

          cond do
            operation in [:pull_requests_get_diff, :pull_requests_get_patch] ->
              Plug.Conn.send_resp(conn, 200, "text output")

            operation == :workflows_list ->
              Req.Test.json(conn, %{"workflows" => [%{"id" => 1}]})

            operation == :files_list ->
              Req.Test.json(conn, [%{"name" => "readme.md"}])

            Keyword.has_key?(definition.params, :return_all) ->
              Req.Test.json(conn, [%{"id" => 1}])

            true ->
              Req.Test.json(conn, %{"id" => 1})
          end
        end)

        assert {:ok, workflow} = Compiler.compile(graph)

        assert {:ok, context} =
                 Credentials.resolve_run_context(
                   graph,
                   workflow,
                   %{},
                   execution_context_fixture()
                 )

        executed =
          workflow
          |> Runic.Workflow.put_run_context(context)
          |> Runic.Workflow.react_until_satisfied(%{})

        assert :ok = Engine.completion(executed)
        assert [_result] = Engine.productions(executed, "action")
        assert {:ok, _module} = Catalog.fetch(definition.id, 1)
      end
    end

    test "publishes the documented n8n action families as versioned nodes" do
      index = Hermitscale.Workflows.Catalog.refresh!()

      for operations <- [GitHub.Operations, Linear.Operations],
          {operation, definition} <- operations.definitions() do
        assert {:ok, module} = Hermitscale.Workflows.Catalog.fetch(index, definition.id, 1)

        assert module.spec().requires == [
                 credentials: [provider: operations.provider_id(), scopes: definition.scopes]
               ]

        assert module.spec().kind == :step
        if definition.effect?, do: assert(module.spec().default_policy.max_retries == 0)
        assert is_atom(operation)
      end

      assert map_size(GitHub.Operations.definitions()) == 47
      assert map_size(Linear.Operations.definitions()) == 7
    end
  end

  defp ref(provider), do: credential_reference_fixture(provider, "data_" <> provider)
end
