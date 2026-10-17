defmodule Hermitscale.Integrations.GitHub do
  @moduledoc "GitHub integration metadata. OAuth tokens and personal access tokens use bearer authentication."
  use Hermitscale.Integrations.Provider

  @impl true
  def provider_id, do: "github"

  @impl true
  def network_domains, do: ["api.github.com"]

  @impl true
  def descriptor do
    %{
      slug: provider_id(),
      auth_methods: ["oauth", "api_key"],
      authentication: %{"oauth" => :bearer, "api_key" => :bearer},
      scope_implications: %{
        "repo" => ["admin:repo_hook", "write:repo_hook", "read:repo_hook"],
        "admin:repo_hook" => ["write:repo_hook", "read:repo_hook"],
        "write:repo_hook" => ["read:repo_hook"],
        "admin:org" => ["write:org", "read:org"],
        "write:org" => ["read:org"]
      },
      destinations: network_domains(),
      git_host: "github.com"
    }
  end
end
