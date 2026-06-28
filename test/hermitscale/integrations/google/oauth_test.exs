defmodule Hermitscale.Integrations.Google.OAuthTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Integrations.Google.OAuth

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  describe "fetch_token/3" do
    test "resolves opaque references through a credential store" do
      store = fn %{"credential_id" => "cred_123"} ->
        {:ok, %{"access_token" => "access_from_store"}}
      end

      assert {:ok, %{access_token: "access_from_store", expires_at: nil}} =
               OAuth.fetch_token(%{"credential_id" => "cred_123"}, [], credential_store: store)
    end

    test "returns an unexpired access token without refreshing" do
      expires_at =
        DateTime.utc_now(:second)
        |> DateTime.add(3_600, :second)

      assert {:ok, %{access_token: "access_123", expires_at: ^expires_at}} =
               OAuth.fetch_token(
                 %{
                   "access_token" => "access_123",
                   "expires_at" => DateTime.to_iso8601(expires_at)
                 },
                 []
               )
    end

    test "refreshes expired credentials through google oauth" do
      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert conn.method == "POST"
        assert conn.request_path == "/token"

        assert %{
                 "client_id" => "client_123",
                 "client_secret" => "secret_123",
                 "grant_type" => "refresh_token",
                 "refresh_token" => "refresh_123",
                 "scope" => "scope:a scope:b"
               } = URI.decode_query(body)

        Req.Test.json(conn, %{"access_token" => "access_new", "expires_in" => 3_600})
      end)

      assert {:ok, %{access_token: "access_new", expires_at: %DateTime{}}} =
               OAuth.fetch_token(
                 %{
                   "access_token" => "access_old",
                   "expires_at" =>
                     DateTime.to_iso8601(DateTime.add(DateTime.utc_now(:second), -60)),
                   "refresh_token" => "refresh_123",
                   "client_id" => "client_123",
                   "client_secret" => "secret_123"
                 },
                 ["scope:a", "scope:b"],
                 plug: {Req.Test, __MODULE__}
               )
    end
  end
end
