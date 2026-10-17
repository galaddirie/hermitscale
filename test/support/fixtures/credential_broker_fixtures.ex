defmodule Hermitscale.CredentialBrokerFixtures do
  @moduledoc false

  import ExUnit.Callbacks

  alias Hermitscale.CredentialBroker
  alias Hermitscale.Workspaces
  alias Hermitscale.WorkOSTest
  alias Hermitscale.WorkspacesTest

  @doc "Stubs Sprites and WorkOS. Each organization has `data_github` and `data_test` accounts."
  def stub_broker_clients(_context) do
    previous = Application.get_env(:hermitscale, Workspaces)
    Application.put_env(:hermitscale, Workspaces, client: WorkspacesTest.Client)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:hermitscale, Workspaces)
        value -> Application.put_env(:hermitscale, Workspaces, value)
      end
    end)

    start_supervised!({WorkspacesTest.Client, []})
    start_supervised!({WorkOSTest.Client, %{}})

    WorkOSTest.Client.put_response(:list_org_providers, fn org_id ->
      {:ok,
       %{
         "data" => [
           %{"slug" => "github", "connected_accounts" => [account("data_github", org_id)]},
           %{"slug" => "test.credentials", "connected_accounts" => [account("data_test", org_id)]}
         ]
       }}
    end)

    :ok
  end

  def grant_fixture(scope, workspace, rules, provider \\ "github") do
    account_id = if provider == "github", do: "data_github", else: "data_test"

    {:ok, grant} =
      CredentialBroker.put_grant(scope, workspace, %{
        provider: provider,
        account_id: account_id,
        rules: rules
      })

    grant
  end

  defp account(id, org_id),
    do: %{
      "id" => id,
      "organization_id" => org_id,
      "user_id" => nil,
      "auth_method" => "oauth",
      "state" => "connected",
      "scopes" => []
    }
end
