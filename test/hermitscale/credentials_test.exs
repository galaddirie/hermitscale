defmodule Hermitscale.CredentialsTest do
  use Hermitscale.DataCase, async: false

  import Hermitscale.CredentialsFixtures

  alias Hermitscale.Credentials
  alias Hermitscale.Credentials.{CredentialEvent, Resolved, TokenCache}
  alias Hermitscale.Credentials.Backends.Local
  alias Hermitscale.Credentials.SecretPayload.{ApiKey, OAuthToken}
  alias Hermitscale.Integrations.Provider

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  defp put_credentials_env(overrides) do
    previous = Application.get_env(:hermitscale, Credentials, [])
    Application.put_env(:hermitscale, Credentials, Keyword.merge(previous, overrides))
    on_exit(fn -> Application.put_env(:hermitscale, Credentials, previous) end)
  end

  defp github_oauth_env do
    put_credentials_env(
      req_options: [plug: {Req.Test, __MODULE__}],
      oauth_clients: %{
        "github" => %{
          client_id: "client_gh",
          client_secret: "secret_gh",
          redirect_uri: "http://localhost:4000/oauth/callback"
        }
      }
    )
  end

  defp actions(credential_id) do
    CredentialEvent
    |> where([e], e.credential_id == ^credential_id)
    |> order_by([e], asc: e.id)
    |> select([e], e.action)
    |> Repo.all()
  end

  describe "create/2 and resolve/2 — api keys" do
    test "stores a key and resolves it to bearer auth" do
      scope = scope_fixture()
      credential = api_key_credential_fixture(scope, %{payload: %ApiKey{key: "ghp_abc"}})

      assert credential.kind == :api_key
      assert credential.method == "api_key"
      assert credential.status == :active
      assert credential.backend == "local"

      assert {:ok, %Resolved{auth: {:bearer, "ghp_abc"}, provider: "github", method: "api_key"}} =
               Credentials.resolve(credential.id)

      assert actions(credential.id) == [:created, :accessed]

      {:ok, reloaded} = Credentials.fetch(credential.id)
      assert %DateTime{} = reloaded.last_used_at
    end

    test "rejects methods the provider does not support" do
      assert {:error, {:method_not_supported, "google.oauth", "api_key"}} =
               Credentials.create(scope_fixture(), %{
                 provider: "google.oauth",
                 payload: %ApiKey{key: "nope"}
               })
    end

    test "resolve enforces accepted methods" do
      credential = api_key_credential_fixture()

      assert {:error, {:method_not_accepted, "api_key"}} =
               Credentials.resolve(credential.id, %{methods: ["oauth"]})

      assert {:ok, %Resolved{}} =
               Credentials.resolve(credential.id, %{methods: ["oauth", "api_key"]})
    end

    test "resolve enforces tenancy scope when given" do
      scope = scope_fixture()
      credential = api_key_credential_fixture(scope)

      assert {:error, :scope_mismatch} =
               Credentials.resolve(credential.id, %{scope: %{org_id: "someone_else"}})

      assert {:ok, %Resolved{}} = Credentials.resolve(credential.id, %{scope: scope})
    end

    test "custom payloads resolve to fields" do
      credential = custom_credential_fixture()

      assert {:ok, %Resolved{auth: {:fields, %{"username" => "svc", "password" => "hunter2"}}}} =
               Credentials.resolve(credential.id)
    end
  end

  describe "resolve/2 — oauth via the local backend" do
    test "a fresh token resolves without touching the network" do
      credential = oauth_credential_fixture()

      assert {:ok, %Resolved{auth: {:bearer, "access_fresh"}, scopes: ["repo"]}} =
               Credentials.resolve(credential.id)

      # Second resolve is served from cache.
      assert {:ok, token} = TokenCache.get(credential.id)
      assert token.access_token == "access_fresh"

      assert {:ok, %Resolved{auth: {:bearer, "access_fresh"}}} =
               Credentials.resolve(credential.id)
    end

    test "scope requirements are subset-checked against the grant" do
      credential = oauth_credential_fixture()

      assert {:error, {:missing_scopes, ["admin:org"]}} =
               Credentials.resolve(credential.id, %{scopes: ["repo", "admin:org"]})
    end

    test "a stale token refreshes, persisting the rotated refresh token before use" do
      github_oauth_env()
      credential = oauth_credential_fixture(scope_fixture(), %{payload: stale_oauth_payload()})

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert conn.request_path == "/login/oauth/access_token"

        assert %{
                 "grant_type" => "refresh_token",
                 "refresh_token" => "refresh_1",
                 "client_id" => "client_gh",
                 "client_secret" => "secret_gh"
               } = URI.decode_query(body)

        Req.Test.json(conn, %{
          "access_token" => "access_new",
          "refresh_token" => "refresh_2",
          "expires_in" => 3_600
        })
      end)

      assert {:ok, %Resolved{auth: {:bearer, "access_new"}}} = Credentials.resolve(credential.id)

      # The rotated refresh token was persisted (rotating-token safety).
      ctx = %{credential_id: credential.id, provider: "github", org_id: credential.org_id}
      assert {:ok, %OAuthToken{refresh_token: "refresh_2"}} = Local.get_secret(credential.id, ctx)

      assert :refreshed in actions(credential.id)
    end

    test "invalid_grant flags the credential for re-auth" do
      github_oauth_env()
      credential = oauth_credential_fixture(scope_fixture(), %{payload: stale_oauth_payload()})

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
      end)

      assert {:error, :reauth_required} = Credentials.resolve(credential.id)

      {:ok, credential} = Credentials.fetch(credential.id)
      assert credential.status == :reauth_required
      assert :reauth_required in actions(credential.id)

      # Subsequent resolves fail fast without another refresh attempt.
      assert {:error, :reauth_required} = Credentials.resolve(credential.id)
    end

    test "a transient token-endpoint failure does not change status" do
      github_oauth_env()
      credential = oauth_credential_fixture(scope_fixture(), %{payload: stale_oauth_payload()})

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, "{}")
      end)

      assert {:error, {:refresh_failed, {:token_endpoint_status, 503}}} =
               Credentials.resolve(credential.id)

      {:ok, credential} = Credentials.fetch(credential.id)
      assert credential.status == :active
    end

    test "an expired token with no refresh token marks the credential expired" do
      credential =
        oauth_credential_fixture(scope_fixture(), %{
          payload: %OAuthToken{
            access_token: "access_stale",
            refresh_token: nil,
            expires_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
          }
        })

      assert {:error, :expired} = Credentials.resolve(credential.id)

      {:ok, credential} = Credentials.fetch(credential.id)
      assert credential.status == :expired
    end

    test "concurrent resolves of a stale token refresh exactly once" do
      github_oauth_env()
      credential = oauth_credential_fixture(scope_fixture(), %{payload: stale_oauth_payload()})

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn conn ->
        Agent.update(counter, &(&1 + 1))

        Req.Test.json(conn, %{
          "access_token" => "access_new",
          "refresh_token" => "refresh_2",
          "expires_in" => 3_600
        })
      end)

      results =
        1..4
        |> Task.async_stream(fn _i -> Credentials.resolve(credential.id) end,
          max_concurrency: 4,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, %Resolved{auth: {:bearer, "access_new"}}}, &1))
      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "rotate/3" do
    test "replaces material, versions it, and invalidates the cache" do
      credential = api_key_credential_fixture(scope_fixture(), %{payload: %ApiKey{key: "old"}})
      assert {:ok, %Resolved{auth: {:bearer, "old"}}} = Credentials.resolve(credential.id)

      assert {:ok, rotated} = Credentials.rotate(credential.id, %ApiKey{key: "new"})
      assert %DateTime{} = rotated.rotated_at

      assert {:ok, %Resolved{auth: {:bearer, "new"}}} = Credentials.resolve(credential.id)
      assert :rotated in actions(credential.id)
    end

    test "rejects a payload of a different kind" do
      credential = api_key_credential_fixture()

      assert {:error, {:kind_mismatch, :api_key, :oauth}} =
               Credentials.rotate(credential.id, %OAuthToken{access_token: "x"})
    end
  end

  describe "revoke/2" do
    test "deletes material and leaves an auditable row" do
      credential = api_key_credential_fixture()

      assert {:ok, revoked} = Credentials.revoke(credential.id)
      assert revoked.status == :revoked
      assert revoked.external_ref == nil

      ctx = %{credential_id: credential.id, provider: "github", org_id: credential.org_id}
      assert {:error, :not_found} = Local.get_secret(credential.id, ctx)

      assert {:error, :revoked} = Credentials.resolve(credential.id)
      assert actions(credential.id) == [:created, :revoked]
      assert {:error, :revoked} = Credentials.revoke(credential.id)
    end
  end

  describe "connect/3 and complete_connect/3 — local backend" do
    test "connect creates a pending credential and an authorization url" do
      github_oauth_env()
      scope = scope_fixture()

      assert {:ok, %{credential: credential, connect: connect}} =
               Credentials.connect(scope, "github", scopes: ["repo"])

      assert credential.status == :pending_connect
      assert connect.state == credential.id
      assert connect.authorization_url =~ "https://github.com/login/oauth/authorize?"
      assert connect.authorization_url =~ "client_id=client_gh"
      assert connect.authorization_url =~ "state=#{credential.id}"

      assert {:error, :pending_connect} = Credentials.resolve(credential.id)
    end

    test "complete_connect exchanges the code and activates the credential" do
      github_oauth_env()

      {:ok, %{credential: credential}} =
        Credentials.connect(scope_fixture(), "github", scopes: ["repo"])

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert %{
                 "grant_type" => "authorization_code",
                 "code" => "auth_code_123",
                 "redirect_uri" => "http://localhost:4000/oauth/callback"
               } = URI.decode_query(body)

        Req.Test.json(conn, %{
          "access_token" => "access_connected",
          "refresh_token" => "refresh_connected",
          "expires_in" => 3_600,
          "scope" => "repo,read:org"
        })
      end)

      assert {:ok, credential} =
               Credentials.complete_connect(credential.id, %{code: "auth_code_123"})

      assert credential.status == :active
      assert credential.scopes == ["repo", "read:org"]

      assert {:ok, %Resolved{auth: {:bearer, "access_connected"}}} =
               Credentials.resolve(credential.id)

      assert :connected in actions(credential.id)
    end

    test "connect without a configured oauth client fails cleanly" do
      put_credentials_env(oauth_clients: %{})

      assert {:error, {:oauth_client_not_configured, "github"}} =
               Credentials.connect(scope_fixture(), "github")

      # The pending row was rolled back.
      assert Credentials.list(%{org_id: "default"}) == []
    end
  end

  describe "provider integration" do
    test "Provider.fetch_token resolves github credentials of either method" do
      credential = api_key_credential_fixture(scope_fixture(), %{payload: %ApiKey{key: "ghp_x"}})

      assert {:ok, %{access_token: "ghp_x"}} =
               Provider.fetch_token("github", %{"credential_id" => credential.id}, [])

      oauth = oauth_credential_fixture()

      assert {:ok, %{access_token: "access_fresh"}} =
               Provider.fetch_token("github", %{"credential_id" => oauth.id}, ["repo"])
    end

    test "unknown references fall through as :unknown_credential" do
      assert {:error, :unknown_credential} =
               Provider.fetch_token("github", %{"credential_id" => Ecto.UUID.generate()}, [])
    end

    test "google legacy refs still resolve through the pre-existing path" do
      expires_at = DateTime.add(DateTime.utc_now(:second), 3_600, :second)

      assert {:ok, %{access_token: "legacy_token"}} =
               Provider.fetch_token(
                 "google.oauth",
                 %{
                   "access_token" => "legacy_token",
                   "expires_at" => DateTime.to_iso8601(expires_at)
                 },
                 []
               )
    end
  end
end
