defmodule Hermitscale.IntegrationsFixtures do
  @moduledoc false

  def execution_context_fixture,
    do: %Hermitscale.Integrations.ExecutionContext{
      organization_id: "org_test",
      actor_user_id: "user_test"
    }

  def account_fixture(provider, org_id \\ "org_test") do
    %{
      "id" => "data_" <> provider,
      "organization_id" => org_id,
      "user_id" => nil,
      "auth_method" => if(provider == "openai", do: "api_key", else: "oauth"),
      "state" => "connected",
      "scopes" => scopes_fixture(provider)
    }
  end

  def scopes_fixture("google"),
    do: [
      "https://www.googleapis.com/auth/spreadsheets",
      "https://www.googleapis.com/auth/spreadsheets.readonly"
    ]

  def scopes_fixture("linear"), do: ["read", "issues:create", "write", "comments:create", "admin"]

  def scopes_fixture("github"),
    do: ["repo", "read:org", "admin:org", "workflow", "admin:repo_hook"]

  def scopes_fixture("openai"), do: []

  def github_issue_fixture,
    do: %{
      "id" => 123,
      "number" => 7,
      "title" => "A task",
      "body" => "Details",
      "state" => "open",
      "html_url" => "https://github.com/acme/backend/issues/7"
    }

  def linear_issue_fixture,
    do: %{
      "id" => "issue_123",
      "identifier" => "ENG-7",
      "title" => "A task",
      "description" => "Details",
      "url" => "https://linear.app/acme/issue/ENG-7"
    }

  def openai_response_fixture do
    %{
      "id" => "resp_123",
      "status" => "completed",
      "model" => "test-model",
      "output" => [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "Hello"}]}
      ],
      "usage" => %{"total_tokens" => 12}
    }
  end
end
