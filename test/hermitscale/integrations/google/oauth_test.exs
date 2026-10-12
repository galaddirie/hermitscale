defmodule Hermitscale.Integrations.Google.OAuthTest do
  use ExUnit.Case, async: false

  alias Hermitscale.Integrations.{ConnectedAccounts, Provider}
  alias Hermitscale.Integrations.Google.OAuth
  alias Hermitscale.WorkOSTest.Client

  import Hermitscale.AccountsFixtures

  setup do
    start_supervised!({Client, %{}})
    previous = Application.get_env(:hermitscale, ConnectedAccounts, [])
    Application.put_env(:hermitscale, ConnectedAccounts, Keyword.put(previous, :client, Client))
    on_exit(fn -> Application.put_env(:hermitscale, ConnectedAccounts, previous) end)

    scope = user_scope_fixture()

    {:ok, reference} =
      ConnectedAccounts.credential_ref(
        {scope.organization.id, scope.user.id},
        "google.oauth",
        ["scope:read"]
      )

    %{reference: reference}
  end

  describe "fetch_token/2" do
    test "vends Google credentials through the provider interface", %{reference: reference} do
      Client.put_response(
        :fetch_oauth_token,
        {:ok,
         %{access_token: "token", expires_at: nil, scopes: ["scope:read"], missing_scopes: []}}
      )

      assert {:ok, %{access_token: "token"}} =
               Provider.fetch_token("google.oauth", reference, [])

      assert Client.calls() == [
               {:fetch_oauth_token, ["google", reference.user_id, reference.organization_id]}
             ]
    end

    test "requires both the reference scopes and caller scopes", %{reference: reference} do
      for granted <- [["scope:read"], ["scope:write"]] do
        Client.put_response(
          :fetch_oauth_token,
          {:ok, %{access_token: "token", expires_at: nil, scopes: granted, missing_scopes: []}}
        )

        assert {:error, :insufficient_scopes} =
                 OAuth.fetch_token(reference, ["scope:write"])
      end
    end

    test "propagates WorkOS revocation", %{reference: reference} do
      Client.put_response(:fetch_oauth_token, {:error, :needs_reauthorization})
      assert {:error, :needs_reauthorization} = OAuth.fetch_token(reference, [])
    end
  end

  test "rejects local access and refresh-token payloads" do
    assert {:error, :missing_credential_identity} =
             OAuth.fetch_token(%{access_token: "legacy", refresh_token: "legacy"}, [])
  end
end
