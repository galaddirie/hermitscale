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

  test "lists events with comma-encoded filters and bearer authentication" do
    range_start = ~U[2026-07-26 12:30:00Z]

    Req.Test.expect(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/events"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk_test_hermitscale"]

      assert conn.query_params == %{
               "after" => "event_previous",
               "events" => "user.updated,session.revoked",
               "limit" => "50",
               "range_start" => "2026-07-26T12:30:00Z"
             }

      Req.Test.json(conn, %{"data" => [], "list_metadata" => %{"after" => nil}})
    end)

    assert {:ok, %{"data" => []}} =
             Client.list_events(
               "event_previous",
               ["user.updated", "session.revoked"],
               limit: 50,
               range_start: range_start
             )
  end

  test "encodes State API filters and paths" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.request_path == "/user_management/organization_memberships"

      assert conn.query_params == %{
               "after" => "membership_previous",
               "limit" => "25",
               "organization_id" => "org_123",
               "statuses" => "active,inactive"
             }

      Req.Test.json(conn, %{"data" => [], "list_metadata" => %{"after" => nil}})
    end)

    assert {:ok, %{"data" => []}} =
             Client.list_organization_memberships(
               "org_123",
               "membership_previous",
               limit: 25,
               statuses: ["active", "inactive"]
             )
  end

  test "retries safe reads but never retries writes" do
    Req.Test.expect(
      __MODULE__,
      2,
      &Plug.Conn.send_resp(&1, 503, Jason.encode!(%{"error" => "unavailable"}))
    )

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"data" => [], "list_metadata" => %{"after" => nil}})
    end)

    assert {:ok, %{"data" => []}} = Client.list_users()

    Req.Test.expect(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 503, Jason.encode!(%{"error" => "unavailable"}))
    end)

    assert {:error, :unavailable} = Client.delete_user("user_123")
  end

  test "normalizes Pipes token states without exposing provider tokens in errors" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "active" => true,
        "access_token" => %{
          "access_token" => "provider-secret",
          "expires_at" => "2026-07-26T13:00:00Z",
          "scopes" => ["scope:a"],
          "missing_scopes" => []
        }
      })
    end)

    assert {:ok,
            %{
              access_token: "provider-secret",
              expires_at: ~U[2026-07-26 13:00:00Z],
              scopes: ["scope:a"],
              missing_scopes: []
            }} = Client.fetch_oauth_token("google", "user_123", nil)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "active" => false,
        "error" => "needs_reauthorization"
      })
    end)

    assert {:error, :needs_reauthorization} =
             Client.fetch_oauth_token("google", "user_123", nil)
  end
end
