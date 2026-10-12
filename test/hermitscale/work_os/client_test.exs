defmodule Hermitscale.WorkOS.ClientTest do
  use ExUnit.Case, async: false

  alias Hermitscale.WorkOS.Client
  import Hermitscale.WorkOS.ClientFixtures

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    previous = Application.get_env(:hermitscale, Client)

    Application.put_env(
      :hermitscale,
      Client,
      previous
      |> Keyword.put(:base_url, "https://api.workos.test")
      |> Keyword.put(:req_options, plug: {Req.Test, __MODULE__})
    )

    on_exit(fn -> Application.put_env(:hermitscale, Client, previous) end)
  end

  test "builds a Hosted AuthKit URL with only supported options" do
    assert {:ok, url} =
             Client.authorization_url("state_123",
               max_age: 600,
               screen_hint: "sign-in"
             )

    uri = URI.parse(url)
    params = URI.decode_query(uri.query)

    assert uri.path == "/user_management/authorize"

    assert params == %{
             "client_id" => "client_test_hermitscale",
             "max_age" => "600",
             "provider" => "authkit",
             "redirect_uri" => "http://www.example.com/auth/workos/callback",
             "response_type" => "code",
             "screen_hint" => "sign-in",
             "state" => "state_123"
           }
  end

  test "retries safe reads but never retries writes" do
    Req.Test.expect(
      __MODULE__,
      2,
      &Plug.Conn.send_resp(&1, 503, Jason.encode!(%{"error" => "unavailable"}))
    )

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"keys" => []})
    end)

    assert {:ok, %{"keys" => []}} = Client.jwks()

    Req.Test.expect(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 503, Jason.encode!(%{"error" => "unavailable"}))
    end)

    assert {:error, :unavailable} = Client.revoke_session("session_123")
  end

  test "normalizes organization Pipes credential states without exposing provider tokens in errors" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/data-integrations/google/credentials"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "user_id" => "user_123",
               "organization_id" => "org_123",
               "connection_owner" => "organization",
               "connected_account_id" => "data_123",
               "supports_multiple_connections" => true
             }

      Req.Test.json(conn, %{
        "active" => true,
        "credential" => %{
          "auth_method" => "oauth",
          "value" => "provider-secret",
          "expires_at" => "2026-07-26T13:00:00Z",
          "scopes" => ["scope:a"],
          "missing_scopes" => []
        }
      })
    end)

    assert {:ok,
            %{
              auth_method: "oauth",
              value: "provider-secret",
              expires_at: ~U[2026-07-26 13:00:00Z],
              scopes: ["scope:a"],
              missing_scopes: []
            }} = Client.vend_credentials("google", "user_123", "org_123", "data_123")

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "active" => false,
        "error" => "needs_reauthorization"
      })
    end)

    assert {:error, :needs_reauthorization} =
             Client.vend_credentials("google", "user_123", "org_123", "data_123")
  end

  test "selection errors and API-key credentials are normalized without reflecting errors" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "active" => true,
        "credential" => %{"auth_method" => "api_key", "value" => "opaque-secret"}
      })
    end)

    assert {:ok, %{auth_method: "api_key", value: "opaque-secret"}} =
             Client.vend_credentials("example", "user_123", "org_123", "data_123")

    for code <- ["account_selection_required", "multiple_connections_unavailable"] do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          422,
          Jason.encode!(%{"code" => code, "message" => "opaque-secret"})
        )
      end)

      assert {:error, reason} =
               Client.vend_credentials("example", "user_123", "org_123", "data_123")

      assert to_string(reason) == code
      refute inspect(reason) =~ "opaque-secret"
    end
  end

  test "malformed successful resource responses return dependency errors" do
    calls = [
      {fn -> Client.authenticate_with_code("code") end, %{"access_token" => "access"}},
      {fn -> Client.authenticate_with_code("code") end,
       %{
         "access_token" => "access",
         "refresh_token" => "refresh",
         "user" => %{"id" => "user_123", "email" => false}
       }},
      {fn -> Client.authenticate_with_refresh_token("refresh", "org_123") end, %{}},
      {fn -> Client.get_organization("org_123") end, %{}},
      {fn -> Client.get_organization_by_external_id("personal:user_123") end, %{"id" => false}},
      {fn -> Client.create_organization(%{"name" => "Workspace"}) end, %{"id" => ""}},
      {fn -> Client.get_membership("om_123") end, %{"id" => "om_123"}},
      {fn -> Client.create_membership("user_123", "org_123", "admin") end, []},
      {fn -> Client.update_membership("om_123", "admin") end, %{}},
      {fn -> Client.get_role("admin") end, %{"permissions" => false}},
      {fn -> Client.list_org_providers("org_123") end,
       %{"data" => [%{"slug" => "google", "connected_accounts" => false}]}},
      {fn ->
         Client.authorize_connection("google", "user_123", "org_123", "https://example.test")
       end, %{"url" => false}}
    ]

    for {call, body} <- calls do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, body))
      assert {:error, :invalid_response} = call.()
    end
  end

  test "valid resource responses retain their WorkOS fields" do
    calls = [
      {fn -> Client.authenticate_with_code("code") end,
       %{
         "access_token" => "access",
         "refresh_token" => "refresh",
         "user" => %{"id" => "user_123"}
       }},
      {fn -> Client.get_organization("org_123") end, %{"id" => "org_123", "name" => "Workspace"}},
      {fn -> Client.get_membership("om_123") end, membership_fixture("om_123")},
      {fn -> Client.get_role("admin") end, %{"permissions" => ["workflows:run"]}},
      {fn -> Client.list_org_providers("org_123") end, %{"data" => [provider_fixture()]}},
      {fn ->
         Client.authorize_connection("google", "user_123", "org_123", "https://example.test")
       end, %{"url" => "https://api.workos.test/authorize"}}
    ]

    for {call, body} <- calls do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, body))
      assert {:ok, ^body} = call.()
    end
  end

  test "membership pagination retains page order and rejects malformed or repeated cursors" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "data" => [membership_fixture("om_first")],
        "list_metadata" => %{"after" => "next"}
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["after"] == "next"

      Req.Test.json(conn, %{
        "data" => [membership_fixture("om_second")],
        "list_metadata" => %{"after" => nil}
      })
    end)

    assert {:ok, %{"data" => [%{"id" => "om_first"}, %{"id" => "om_second"}]}} =
             Client.list_memberships("user_123")

    for page <- [
          %{"data" => false},
          %{"data" => [false]},
          %{"data" => [], "list_metadata" => false},
          %{"data" => [], "list_metadata" => %{"after" => 42}},
          %{"data" => [], "list_metadata" => %{"after" => ""}}
        ] do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, page))
      assert {:error, :invalid_response} = Client.list_memberships("user_123")
    end

    attempts = start_supervised!({Agent, fn -> 0 end}, id: :pagination_attempts)

    Req.Test.stub(__MODULE__, fn conn ->
      count = Agent.get_and_update(attempts, fn count -> {count, count + 1} end)

      page =
        if count < 2,
          do: %{"data" => [], "list_metadata" => %{"after" => "repeated"}},
          else: %{"data" => []}

      Req.Test.json(conn, page)
    end)

    assert {:error, :invalid_response} = Client.list_memberships("user_123")
    assert Agent.get(attempts, & &1) == 2
  end

  test "invalid optional credential expiry and scopes cannot become usable credentials" do
    for overrides <- [
          %{"expires_at" => false},
          %{"expires_at" => "not-a-date"},
          %{"scopes" => false},
          %{"missing_scopes" => false},
          %{"scopes" => [false]}
        ] do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, credential_fixture(overrides)))

      assert {:error, :invalid_credential_response} =
               Client.vend_credentials("google", "user_123", "org_123", "data_123")
    end

    for expiry <- [nil, DateTime.utc_now(:second) |> DateTime.add(300) |> DateTime.to_iso8601()] do
      Req.Test.expect(
        __MODULE__,
        &Req.Test.json(&1, credential_fixture(%{"expires_at" => expiry}))
      )

      assert {:ok, %{expires_at: parsed}} =
               Client.vend_credentials("google", "user_123", "org_123", "data_123")

      assert is_nil(parsed) or match?(%DateTime{}, parsed)
    end
  end
end
