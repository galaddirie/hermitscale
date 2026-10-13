defmodule Hermitscale.WorkflowExternalFixtures do
  @moduledoc false
  import Hermitscale.WorkflowsFixtures
  import Hermitscale.IntegrationsFixtures

  def coding_graph do
    valid_join_graph(%{
      "id" => "wf_coding",
      "name" => "Coding",
      "nodes" => [coding_node()],
      "connections" => []
    })
  end

  def coding_publication_graph do
    valid_join_graph(%{
      "id" => "wf_coding_publication",
      "name" => "Coding publication",
      "nodes" => [
        coding_node(),
        %{
          "id" => "publish",
          "type" => "agents.publish_branch",
          "version" => 1,
          "params" => %{
            "session_id" => "{{ $json.session_id }}",
            "branch" => "automation/update",
            "base_sha" => "{{ $json.base_sha }}",
            "manifest" => "{{ $json.manifest }}",
            "message" => "Update source",
            "candidate_digest" => "{{ $json.candidate_digest }}",
            "patch_snapshot_artifact_id" => "{{ $json.patch_snapshot_artifact_id }}"
          }
        },
        %{
          "id" => "pull",
          "type" => "github.pull_requests.create",
          "version" => 1,
          "connection" => %{"provider" => "github", "account_id" => "data_github"},
          "params" => %{
            "owner" => "acme",
            "repo" => "backend",
            "title" => "Update source",
            "head" => "{{ $json.branch }}",
            "base" => "main",
            "body" => "Verified workflow changes"
          }
        },
        %{
          "id" => "notify",
          "type" => "linear.comments.create",
          "version" => 1,
          "connection" => %{"provider" => "linear", "account_id" => "data_linear"},
          "params" => %{"issue_id" => "issue-id", "body" => "Ready: {{ $json.html_url }}"}
        }
      ],
      "connections" => [
        %{"from" => "coding", "to" => "publish"},
        %{"from" => "publish", "to" => "pull"},
        %{"from" => "pull", "to" => "notify"}
      ]
    })
  end

  def mapped_coding_graph do
    valid_join_graph(%{
      "id" => "wf_mapped_coding",
      "name" => "Mapped coding",
      "nodes" => [
        %{"id" => "items", "type" => "map", "version" => 1, "params" => %{}},
        coding_node(),
        %{"id" => "results", "type" => "aggregate", "version" => 1, "params" => %{}}
      ],
      "connections" => [
        %{"from" => "items", "to" => "coding"},
        %{"from" => "coding", "to" => "results"}
      ]
    })
  end

  def retired_workflow_definition do
    valid_join_graph(%{
      "id" => "wf_retired",
      "name" => "Retired workflow",
      "nodes" => [
        %{
          "id" => "investigate",
          "type" => "support.investigate",
          "version" => 1,
          "params" => %{"subscription_id" => Ecto.UUID.generate(), "ticket_id" => "issue-id"}
        }
      ],
      "connections" => []
    })
  end

  def coding_result do
    %{
      "session_id" => Ecto.UUID.generate(),
      "base_sha" => String.duplicate("a", 40),
      "manifest" => ["lib/change.ex"],
      "summary" => "Fixed and verified",
      "candidate_digest" => String.duplicate("c", 64),
      "patch_snapshot_artifact_id" => Ecto.UUID.generate()
    }
  end

  def publication_result do
    %{
      "repository" => "acme/backend",
      "branch" => "automation/update",
      "commit_sha" => String.duplicate("b", 40)
    }
  end

  def provider_account_fixture(provider, org_id) do
    provider
    |> account_fixture(org_id)
    |> Map.put("scopes", write_scopes_fixture(provider))
  end

  def write_scopes_fixture("github"), do: ["repo"]
  def write_scopes_fixture("linear"), do: ["comments:create"]

  defp coding_node do
    %{
      "id" => "coding",
      "type" => "agents.codex.run",
      "version" => 1,
      "params" => %{
        "instructions" => "Update the source and verify the changes",
        "repository" => "acme/backend",
        "base_sha" => String.duplicate("a", 40)
      }
    }
  end
end
