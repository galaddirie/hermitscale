defmodule Hermitscale.Integrations.ClientsTest do
  use ExUnit.Case, async: false

  alias Hermitscale.Integrations.{GitHub, Linear, OpenAI}
  alias Hermitscale.WorkOSTest.Client, as: Pipes
  import Hermitscale.IntegrationsFixtures
  import Hermitscale.WorkflowsFixtures, only: [credential_reference_fixture: 2]

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

    %{opts: [plug: {Req.Test, __MODULE__}]}
  end

  describe "GitHub issues" do
    test "reads an issue with versioned headers and encoded path segments", %{opts: opts} do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/repos/acme%2Fteam/backend/issues/7"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer provider-secret"]
        assert Plug.Conn.get_req_header(conn, "accept") == ["application/vnd.github+json"]
        assert Plug.Conn.get_req_header(conn, "x-github-api-version") == ["2026-03-10"]
        Req.Test.json(conn, github_issue_fixture())
      end)

      assert {:ok, %{"number" => 7}} =
               GitHub.Client.get_issue(ref("github"), "acme/team", "backend", 7, opts)
    end

    test "creates an issue once and sends the provided content", %{opts: opts} do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/repos/acme/backend/issues"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"title" => "A task", "body" => "Details"}
        Req.Test.json(conn, github_issue_fixture())
      end)

      assert {:ok, %{"id" => 123}} =
               GitHub.Client.create_issue(
                 ref("github"),
                 "acme",
                 "backend",
                 %{"title" => "A task", "body" => "Details"},
                 opts
               )
    end
  end

  describe "Linear issues" do
    test "uses GraphQL variables instead of interpolating an issue identifier", %{opts: opts} do
      id = "ENG-7\" injected"

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/graphql"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer provider-secret"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["variables"] == %{"id" => id}
        refute decoded["query"] =~ id
        Req.Test.json(conn, %{"data" => %{"issue" => linear_issue_fixture()}})
      end)

      assert {:ok, %{"identifier" => "ENG-7"}} = Linear.Client.get_issue(ref("linear"), id, opts)
    end

    test "creates an issue using a typed input variable", %{opts: opts} do
      input = %{"teamId" => "team_123", "title" => "A task", "description" => "Details"}

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["variables"] == %{"input" => input}

        Req.Test.json(conn, %{
          "data" => %{"issueCreate" => %{"success" => true, "issue" => linear_issue_fixture()}}
        })
      end)

      assert {:ok, %{"id" => "issue_123"}} =
               Linear.Client.create_issue(ref("linear"), input, opts)
    end

    test "personal API keys use the raw Authorization value", %{opts: opts} do
      account = Map.put(account_fixture("linear"), "auth_method", "api_key")

      Pipes.put_response(
        :list_org_providers,
        {:ok, %{"data" => [%{"slug" => "linear", "connected_accounts" => [account]}]}}
      )

      Pipes.put_response(
        :vend_credentials,
        {:ok, %{auth_method: "api_key", value: "linear-api-key", scopes: [], missing_scopes: []}}
      )

      Req.Test.expect(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["linear-api-key"]
        Req.Test.json(conn, %{"data" => %{"issue" => linear_issue_fixture()}})
      end)

      assert {:ok, _issue} = Linear.Client.get_issue(ref("linear"), "ENG-7", opts)
    end

    test "rejects partial GraphQL results and a failed mutation", %{opts: opts} do
      Req.Test.expect(
        __MODULE__,
        &Req.Test.json(&1, %{
          "data" => %{"issue" => linear_issue_fixture()},
          "errors" => [%{"message" => "secret details"}]
        })
      )

      assert {:error, :linear_graphql_error} =
               Linear.Client.get_issue(ref("linear"), "ENG-7", opts)

      Req.Test.expect(
        __MODULE__,
        &Req.Test.json(&1, %{"data" => %{"issueCreate" => %{"success" => false, "issue" => nil}}})
      )

      assert {:error, :linear_mutation_failed} =
               Linear.Client.create_issue(
                 ref("linear"),
                 %{"teamId" => "team_123", "title" => "A task"},
                 opts
               )
    end
  end

  describe "OpenAI responses" do
    test "uses a vended API key and sends a synchronous response request", %{opts: opts} do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/responses"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer provider-secret"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "model" => "test-model",
                 "input" => "Say hello",
                 "store" => false,
                 "stream" => false,
                 "background" => false
               }

        Req.Test.json(conn, openai_response_fixture())
      end)

      assert {:ok, %{"id" => "resp_123", "output_text" => "Hello"}} =
               OpenAI.Client.create_response(
                 ref("openai"),
                 %{"model" => "test-model", "input" => "Say hello"},
                 opts
               )
    end

    test "reports incomplete and failed model responses as failures", %{opts: opts} do
      for status <- ["incomplete", "failed", "queued", "in_progress"] do
        Req.Test.expect(
          __MODULE__,
          &Req.Test.json(&1, %{openai_response_fixture() | "status" => status})
        )

        assert {:error, {:openai_response_not_completed, ^status}} =
                 OpenAI.Client.create_response(
                   ref("openai"),
                   %{"model" => "test-model", "input" => "Hello"},
                   opts
                 )
      end
    end
  end

  describe "provider failure boundaries" do
    test "does not expose error bodies or retry writes", %{opts: opts} do
      for {provider, call} <- calls(opts) do
        Req.Test.expect(__MODULE__, fn conn ->
          conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"secret" => "provider-secret"})
        end)

        assert {:error, {:provider_request_failed, 503}} = call.(ref(provider))
      end
    end

    test "rejects malformed successful responses", %{opts: opts} do
      for {provider, call} <- calls(opts) do
        Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"unexpected" => "provider-secret"}))
        assert {:error, reason} = call.(ref(provider))

        assert reason in [
                 :invalid_github_response,
                 :invalid_linear_response,
                 :invalid_openai_response
               ]
      end
    end

    test "checks membership before any external request", %{opts: opts} do
      Pipes.put_response(:list_memberships, {:ok, %{"data" => []}})

      for {provider, call} <- calls(opts),
          do: assert({:error, :execution_actor_ineligible} = call.(ref(provider)))

      refute Enum.any?(Pipes.calls(), fn {operation, _args} -> operation == :vend_credentials end)
    end

    test "rejects credentials for another provider before vending", %{opts: opts} do
      assert {:error, :unapproved_destination} =
               GitHub.Client.get_issue(ref("openai"), "acme", "backend", 7, opts)

      refute Enum.any?(Pipes.calls(), fn {operation, _args} -> operation == :vend_credentials end)
    end
  end

  defp calls(opts),
    do: [
      {"github",
       &GitHub.Client.create_issue(&1, "acme", "backend", %{"title" => "A task"}, opts)},
      {"linear",
       &Linear.Client.create_issue(&1, %{"teamId" => "team_123", "title" => "A task"}, opts)},
      {"openai",
       &OpenAI.Client.create_response(&1, %{"model" => "test-model", "input" => "Hello"}, opts)}
    ]

  defp ref(provider), do: credential_reference_fixture(provider, "data_" <> provider)
end
