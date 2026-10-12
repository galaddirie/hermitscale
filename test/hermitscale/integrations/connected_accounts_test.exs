defmodule Hermitscale.Integrations.ConnectedAccountsTest do
  use ExUnit.Case, async: false

  alias Hermitscale.Integrations.{ConnectedAccounts, CredentialRef}
  alias Hermitscale.WorkOSTest.Client
  import Hermitscale.AccountsFixtures

  setup do
    start_supervised!({Client, %{}})
    previous = Application.get_env(:hermitscale, ConnectedAccounts, [])
    Application.put_env(:hermitscale, ConnectedAccounts, client: Client)
    on_exit(fn -> Application.put_env(:hermitscale, ConnectedAccounts, previous) end)
    %{scope: user_scope_fixture()}
  end

  describe "WorkOS Pipes credentials" do
    test "vends fresh tokens from trusted ownership metadata on every request", %{scope: scope} do
      identity = {scope.organization.id, scope.user.id}

      assert {:ok, %CredentialRef{} = ref} =
               ConnectedAccounts.credential_ref(identity, "google.oauth", ["scope:a"])

      refute Map.has_key?(Map.from_struct(ref), :access_token)

      Client.put_response(
        :fetch_oauth_token,
        {:ok, %{access_token: "token", expires_at: nil, scopes: ["scope:a"], missing_scopes: []}}
      )

      for _ <- 1..2 do
        assert {:ok, %{access_token: "token"}} = ConnectedAccounts.fetch_oauth_token(ref)
      end

      assert Client.calls() == [
               {:fetch_oauth_token, ["google", scope.user.id, scope.organization.id]},
               {:fetch_oauth_token, ["google", scope.user.id, scope.organization.id]}
             ]
    end

    test "rejects missing identities and unknown providers before making requests", %{
      scope: scope
    } do
      assert {:error, :missing_credential_identity} =
               ConnectedAccounts.credential_ref(
                 {scope.organization.id, "legacy-user-1"},
                 "google.oauth",
                 []
               )

      assert {:error, :unknown_provider} =
               ConnectedAccounts.credential_ref(
                 {scope.organization.id, scope.user.id},
                 "unconfigured",
                 []
               )

      assert Client.calls() == []
    end

    test "honors missing scopes and remote revocation without local state", %{scope: scope} do
      {:ok, ref} =
        ConnectedAccounts.credential_ref({scope.organization.id, scope.user.id}, "google.oauth", [
          "scope:a"
        ])

      Client.put_response(
        :fetch_oauth_token,
        {:ok, %{access_token: "token", expires_at: nil, scopes: [], missing_scopes: ["scope:a"]}}
      )

      assert {:error, :insufficient_scopes} = ConnectedAccounts.fetch_oauth_token(ref)
      Client.put_response(:fetch_oauth_token, {:error, :needs_reauthorization})
      assert {:error, :needs_reauthorization} = ConnectedAccounts.fetch_oauth_token(ref)
    end
  end
end
