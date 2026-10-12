defmodule Hermitscale.Workflows.Nodes.IntegrationsTest do
  use ExUnit.Case, async: false
  alias Hermitscale.Integrations.{ConnectedAccounts, Provider}
  alias Hermitscale.Workflows.{Catalog, Compiler, Credentials, Engine}
  alias Hermitscale.WorkOSTest.Client, as: Pipes
  alias Runic.Workflow.SingleOutput.Result
  import Hermitscale.IntegrationsFixtures

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    start_supervised!(Pipes)

    Pipes.put_response(
      :list_org_providers,
      {:ok,
       %{
         "data" =>
           for(
             provider <- ~w(github linear openai),
             do: %{"slug" => provider, "connected_accounts" => [account_fixture(provider)]}
           )
       }}
    )

    Pipes.put_response(:vend_credentials, fn provider, _user, _org, _id ->
      {:ok,
       %{
         auth_method: if(provider == "openai", do: "api_key", else: "oauth"),
         value: "provider-secret",
         scopes: scopes_fixture(provider),
         missing_scopes: []
       }}
    end)

    for client <- [
          Hermitscale.Integrations.GitHub.Client,
          Hermitscale.Integrations.Linear.Client,
          Hermitscale.Integrations.OpenAI.Client
        ] do
      previous = Application.get_env(:hermitscale, client)
      Application.put_env(:hermitscale, client, req_options: [plug: {Req.Test, __MODULE__}])

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:hermitscale, client),
          else: Application.put_env(:hermitscale, client, previous)
      end)
    end

    :ok
  end

  describe "integration catalog and execution" do
    test "discovers providers and credentialed versioned nodes" do
      Provider.refresh!()
      Catalog.refresh!()

      for {type, provider, params, scopes} <- cases() do
        assert {:ok, module} = Catalog.fetch(type, 1)
        assert module.spec().requires == [credentials: [provider: provider, scopes: scopes]]
        assert {:ok, _descriptor} = Provider.descriptor(provider)
        assert {:ok, _workflow} = Compiler.compile(graph(type, provider, params))
      end
    end

    test "executes each node with its selected organization account" do
      for {type, provider, params, scopes} <- cases() do
        module = Catalog.fetch!(type, 1)
        selection = %{"provider" => provider, "account_id" => "data_" <> provider}

        assert {:ok, ref} =
                 ConnectedAccounts.credential_ref(execution_context_fixture(), selection, scopes)

        Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, response(type)) end)
        assert %{} = module.work(params, %{}, %{credentials: ref})
      end
    end

    test "provider failures become node failures instead of successful error data" do
      for {type, provider, params, scopes} <- cases() do
        module = Catalog.fetch!(type, 1)
        selection = %{"provider" => provider, "account_id" => "data_" <> provider}

        assert {:ok, ref} =
                 ConnectedAccounts.credential_ref(execution_context_fixture(), selection, scopes)

        # 400 is terminal for both read and write HTTP operations.
        Req.Test.expect(__MODULE__, fn conn ->
          conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "private details"})
        end)

        assert module.work(params, %{}, %{credentials: ref}) ==
                 Result.failure({:provider_request_failed, 400})
      end
    end

    test "compiled graphs execute through the workflow engine with non-secret runtime references" do
      for {type, provider, params, _scopes} <- cases() do
        graph = graph(type, provider, params)
        assert {:ok, workflow} = Compiler.compile(graph)

        assert {:ok, context} =
                 Credentials.resolve_run_context(
                   graph,
                   workflow,
                   %{},
                   execution_context_fixture()
                 )

        Req.Test.expect(__MODULE__, &Req.Test.json(&1, response(type)))

        executed =
          workflow
          |> Runic.Workflow.put_run_context(context)
          |> Runic.Workflow.react_until_satisfied(%{})

        assert :ok = Engine.completion(executed)
        assert [%{} = output] = Engine.productions(executed, "action")
        refute Jason.encode!(output) =~ "provider-secret"
      end
    end

    test "write nodes default to zero retries" do
      for type <- ["github.issues.create", "linear.issues.create", "openai.responses.create"] do
        assert Catalog.fetch!(type, 1).spec().default_policy.max_retries == 0
      end
    end
  end

  defp cases,
    do: [
      {"github.issues.get", "github", %{owner: "acme", repo: "backend", issue_number: 7},
       ["repo"]},
      {"github.issues.create", "github",
       %{owner: "acme", repo: "backend", title: "A task", body: "Details"}, ["repo"]},
      {"linear.issues.get", "linear", %{issue_id: "ENG-7"}, ["read"]},
      {"linear.issues.create", "linear",
       %{team_id: "team_123", title: "A task", description: "Details"}, ["issues:create"]},
      {"openai.responses.create", "openai",
       %{
         model: "test-model",
         input: "Hello",
         instructions: "Be concise",
         max_output_tokens: 1000
       }, []}
    ]

  defp response("github." <> _rest), do: github_issue_fixture()
  defp response("linear.issues.get"), do: %{"data" => %{"issue" => linear_issue_fixture()}}

  defp response("linear.issues.create"),
    do: %{"data" => %{"issueCreate" => %{"success" => true, "issue" => linear_issue_fixture()}}}

  defp response("openai.responses.create"), do: openai_response_fixture()

  defp graph(type, provider, params),
    do: %{
      "schema_version" => 1,
      "id" => "wf_integration",
      "name" => "integration",
      "nodes" => [
        %{
          "id" => "action",
          "type" => type,
          "version" => 1,
          "params" => Map.new(params, fn {key, value} -> {Atom.to_string(key), value} end),
          "connection" => %{"provider" => provider, "account_id" => "data_" <> provider}
        }
      ],
      "connections" => []
    }
end
