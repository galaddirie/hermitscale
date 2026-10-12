defmodule Hermitscale.Workflows.CredentialsTest do
  use ExUnit.Case, async: true

  import Hermitscale.WorkflowsFixtures

  alias Hermitscale.Workflows.{Compiler, Credentials}
  alias Runic.Workflow

  describe "WorkOS Pipes identity" do
    test "uses authoritative ownership rather than supplied binding IDs" do
      graph =
        google_graph(%{
          "provider" => "google.oauth",
          "user_id" => "user_victim",
          "organization_id" => "org_victim"
        })

      assert {:ok, workflow} = Compiler.compile(graph)

      assert {:ok, %{"read" => %{credentials: reference}}} =
               Credentials.resolve_run_context(
                 graph,
                 workflow,
                 %{},
                 {"org_authoritative", "user_creator"}
               )

      assert reference.user_id == "user_creator"
      assert reference.organization_id == "org_authoritative"
      refute Map.has_key?(Map.from_struct(reference), :access_token)
    end

    test "legacy local connected-account IDs fail closed" do
      graph = google_graph(%{"provider" => "google.oauth", "connected_account_id" => "local-id"})
      assert {:ok, workflow} = Compiler.compile(graph)

      assert {:error,
              {:credential_fetch_failed, "read", "google.oauth", :legacy_credential_reference}} =
               Credentials.resolve_run_context(
                 graph,
                 workflow,
                 %{},
                 {"org_authoritative", "user_creator"}
               )
    end
  end

  describe "resolve_run_context/3" do
    test "resolves provider defaults into per-node run context" do
      graph = credential_probe_graph()
      assert {:ok, workflow} = Compiler.compile(graph)

      assert {:ok, context} = Credentials.resolve_run_context(graph, workflow)

      assert %{
               "probe" => %{
                 credentials: %{
                   access_token: "token:cred_default",
                   expires_at: nil,
                   scopes: ["scope:a"]
                 }
               }
             } = context

      assert :ok = Workflow.validate_run_context(workflow, context)

      results =
        workflow
        |> Workflow.put_run_context(context)
        |> Workflow.react_until_satisfied(%{"input" => true})
        |> Workflow.raw_productions()

      assert Enum.any?(
               results,
               &match?(
                 %{
                   "input" => true,
                   "access_token" => "token:cred_default",
                   "scopes" => ["scope:a"]
                 },
                 &1
               )
             )
    end

    test "node overrides take precedence over provider defaults" do
      graph =
        credential_probe_graph(%{
          "credentials" => %{
            "providers" => %{
              "test.credentials" => %{
                "provider" => "test.credentials",
                "credential_id" => "cred_default"
              }
            },
            "nodes" => %{
              "probe" => %{
                "provider" => "test.credentials",
                "credential_id" => "cred_override"
              }
            }
          }
        })

      assert {:ok, workflow} = Compiler.compile(graph)

      assert {:ok,
              %{
                "probe" => %{credentials: %{access_token: "token:cred_override"}}
              }} = Credentials.resolve_run_context(graph, workflow)
    end

    test "returns missing run context when a required credential has no binding" do
      graph = credential_probe_graph(%{"credentials" => %{}})
      assert {:ok, workflow} = Compiler.compile(graph)

      assert {:error, {:missing_run_context, %{"probe" => [:credentials]}}} =
               Credentials.resolve_run_context(graph, workflow)
    end

    test "returns provider resolution failures without exposing the reference" do
      graph =
        credential_probe_graph(%{
          "credentials" => %{
            "providers" => %{
              "test.credentials" => %{
                "provider" => "test.credentials",
                "credential_id" => "cred_fail",
                "fail" => true
              }
            }
          }
        })

      assert {:ok, workflow} = Compiler.compile(graph)

      assert {:error,
              {:credential_fetch_failed, "probe", "test.credentials", :test_provider_failed}} =
               Credentials.resolve_run_context(graph, workflow)
    end
  end

  defp google_graph(ref) do
    %{
      "schema_version" => 1,
      "id" => "google_read",
      "name" => "Google read",
      "nodes" => [
        %{
          "id" => "read",
          "type" => "google.sheets.read_rows",
          "version" => 1,
          "params" => %{"spreadsheet_id" => "sheet"}
        }
      ],
      "connections" => [],
      "credentials" => %{"providers" => %{"google.oauth" => ref}}
    }
  end
end
