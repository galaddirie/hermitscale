defmodule Hermitscale.CredentialBrokerTest do
  use Hermitscale.DataCase, async: false

  import Hermitscale.AccountsFixtures
  import Hermitscale.CredentialBrokerFixtures
  import Hermitscale.WorkspacesFixtures

  alias Hermitscale.CredentialBroker
  alias Hermitscale.CredentialBroker.{Grant, Token}
  alias Hermitscale.Integrations.CredentialRef
  alias Hermitscale.Workspaces

  setup :stub_broker_clients

  setup do
    scope = user_scope_fixture()
    %{scope: scope, workspace: workspace_fixture(scope)}
  end

  describe "grants" do
    test "attach a connected account with rules, one per provider", %{
      scope: scope,
      workspace: workspace
    } do
      assert {:ok, grant} =
               CredentialBroker.put_grant(scope, workspace, %{
                 provider: "github",
                 account_id: "data_github",
                 rules: ["GET /repos/acme/*", "FETCH /acme/web"],
                 org_id: "org_forged",
                 workspace_id: "forged"
               })

      assert grant.org_id == scope.organization.id
      assert grant.workspace_id == workspace.id
      assert grant.created_by_user_id == scope.user.id

      assert {:ok, replaced} =
               CredentialBroker.put_grant(scope, workspace, %{
                 provider: "github",
                 account_id: "data_github",
                 rules: ["* /*"]
               })

      assert replaced.id == grant.id
      assert {:ok, [%Grant{rules: ["* /*"]}]} = CredentialBroker.list_grants(scope, workspace)

      assert {:ok, _deleted} = CredentialBroker.delete_grant(scope, workspace, "github")
      assert {:ok, []} = CredentialBroker.list_grants(scope, workspace)
    end

    test "require valid rules and an account the organization connected", %{
      scope: scope,
      workspace: workspace
    } do
      for rules <- [[], ["GET repos"], ["SEND /x"], ["GET /a*b"], ["GET /a b"]] do
        assert {:error, changeset} =
                 CredentialBroker.put_grant(scope, workspace, %{
                   provider: "github",
                   account_id: "data_github",
                   rules: rules
                 })

        assert %{rules: [_message]} = errors_on(changeset)
      end

      assert {:error, :account_not_found} =
               CredentialBroker.put_grant(scope, workspace, %{
                 provider: "github",
                 account_id: "data_test",
                 rules: ["* /*"]
               })

      assert {:error, :unknown_provider} =
               CredentialBroker.put_grant(scope, workspace, %{
                 provider: "nope",
                 account_id: "data_github",
                 rules: ["* /*"]
               })
    end

    test "require connections:manage and the caller's organization", %{
      scope: scope,
      workspace: workspace
    } do
      runner = put_in(scope.membership.permissions, ["workflows:run"])
      outsider = user_scope_fixture()
      attrs = %{provider: "github", account_id: "data_github", rules: ["* /*"]}

      assert {:error, :forbidden} = CredentialBroker.put_grant(runner, workspace, attrs)
      assert {:error, :forbidden} = CredentialBroker.delete_grant(runner, workspace, "github")
      assert {:error, :not_found} = CredentialBroker.put_grant(outsider, workspace, attrs)
      assert {:error, :not_found} = CredentialBroker.list_grants(outsider, workspace)
    end
  end

  describe "tokens" do
    test "store only a hash and expire", %{scope: scope, workspace: workspace} do
      assert {:ok, "hsb_" <> _ = secret, token} =
               CredentialBroker.issue_token(scope, workspace, ttl: 60)

      assert token.token_hash == :crypto.hash(:sha256, secret)
      assert token.actor_user_id == scope.user.id
      assert DateTime.diff(token.expires_at, DateTime.utc_now()) in 58..60
      refute inspect(token) =~ secret

      for ttl <- [0, 86_401, "60"] do
        assert {:error, :invalid_ttl} = CredentialBroker.issue_token(scope, workspace, ttl: ttl)
      end

      assert %{"HERMITSCALE_BROKER_TOKEN" => ^secret, "HERMITSCALE_BROKER_URL" => url} =
               CredentialBroker.env(secret)

      assert url =~ ~r{/broker/v1$}
    end

    test "can be revoked only within the organization", %{scope: scope, workspace: workspace} do
      {:ok, secret, token} = CredentialBroker.issue_token(scope, workspace)
      grant_fixture(scope, workspace, ["* /*"])

      assert {:error, :not_found} = CredentialBroker.revoke_token(user_scope_fixture(), token.id)
      assert {:ok, _access} = CredentialBroker.authorize(secret, "github", "GET", "/user")

      assert :ok = CredentialBroker.revoke_token(scope, token.id)

      assert {:error, :unauthorized} =
               CredentialBroker.authorize(secret, "github", "GET", "/user")

      assert {:error, :not_found} = CredentialBroker.revoke_token(scope, token.id)
    end
  end

  describe "authorize/4" do
    setup %{scope: scope, workspace: workspace} do
      grant_fixture(scope, workspace, ["GET /repos/acme/*", "POST /graphql", "FETCH /acme/web"])
      {:ok, secret, token} = CredentialBroker.issue_token(scope, workspace)
      %{secret: secret, token: token}
    end

    test "returns a credential reference for the acting member", %{scope: scope, secret: secret} do
      assert {:ok, %{ref: ref}} =
               CredentialBroker.authorize(secret, "github", "GET", "/repos/acme/web/issues")

      assert %CredentialRef{provider_id: "github", account_id: "data_github"} = ref
      assert ref.execution_context.organization_id == scope.organization.id
      assert ref.execution_context.actor_user_id == scope.user.id

      assert {:ok, _access} = CredentialBroker.authorize(secret, "github", "FETCH", "/acme/web")
      assert {:ok, _access} = CredentialBroker.authorize(secret, "github", "POST", "/graphql")
    end

    test "rejects requests outside the rules", %{secret: secret} do
      for {method, path} <- [
            {"DELETE", "/repos/acme/web"},
            {"GET", "/repos/other/web"},
            {"GET", "/repos/acme"},
            {"PUSH", "/acme/web"},
            {"FETCH", "/acme/web2"},
            {"POST", "/graphql/extra"}
          ] do
        assert {:error, :endpoint_not_allowed} =
                 CredentialBroker.authorize(secret, "github", method, path)
      end

      assert {:error, :not_granted} =
               CredentialBroker.authorize(secret, "test.credentials", "GET", "/x")
    end

    test "rejects unknown, expired, and orphaned tokens", %{
      scope: scope,
      workspace: workspace,
      secret: secret,
      token: token
    } do
      for forged <- [nil, "", "hsb_forged", String.replace_prefix(secret, "hsb_", "")] do
        assert {:error, :unauthorized} = CredentialBroker.authorize(forged, "github", "GET", "/")
      end

      token
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1))
      |> Repo.update!()

      assert {:error, :unauthorized} =
               CredentialBroker.authorize(secret, "github", "GET", "/repos/acme/web")

      {:ok, live, _token} = CredentialBroker.issue_token(scope, workspace)
      {:ok, _deleted} = Workspaces.delete_workspace(scope, workspace)

      assert {:error, :unauthorized} =
               CredentialBroker.authorize(live, "github", "GET", "/repos/acme/web")

      assert Repo.aggregate(Token, :count) == 0
    end
  end
end
