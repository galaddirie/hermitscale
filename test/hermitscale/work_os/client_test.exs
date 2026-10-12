defmodule Hermitscale.WorkOS.ClientTest do
  use ExUnit.Case, async: false

  alias Hermitscale.WorkOS.Client

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
end
