defmodule Hermitscale.Integrations.RequestTest do
  use ExUnit.Case, async: false
  import Hermitscale.WorkflowsFixtures
  alias Hermitscale.Integrations.Request
  alias Hermitscale.WorkOSTest.Client

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    start_supervised!({Client, %{}})
    %{ref: credential_reference_fixture("test.credentials", "data_test")}
  end

  describe "credentialed effects" do
    test "checks dynamic destinations before vending", %{ref: ref} do
      for url <- [
            "http://test.local",
            "https://evil.test",
            "https://test.local.evil.test",
            "https://user@test.local",
            "https://test.local:8443",
            "//test.local"
          ] do
        assert {:error, :unapproved_destination} = Request.request(:get, url, ref)
      end

      assert Client.calls() == []
    end

    test "does not follow redirects or return provider secrets", %{ref: ref} do
      Req.Test.expect(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer access_123"]

        conn
        |> Plug.Conn.put_resp_header("location", "https://evil.test")
        |> Plug.Conn.send_resp(302, "redirect")
      end)

      assert {:error, :redirect_not_allowed} =
               Request.request(:get, "https://test.local", ref, plug: {Req.Test, __MODULE__})

      Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, %{"echo" => "access_123"}) end)

      assert {:ok, %{body: %{"echo" => "[REDACTED]"}}} =
               Request.request(:get, "https://test.local", ref, plug: {Req.Test, __MODULE__})
    end

    test "safe request retries vend again and pick up rotation", %{ref: ref} do
      Client.put_response(
        :vend_credentials,
        {:ok, %{auth_method: "oauth", value: "first", scopes: [], missing_scopes: []}}
      )

      Req.Test.expect(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer first"]

        Client.put_response(
          :vend_credentials,
          {:ok, %{auth_method: "oauth", value: "rotated", scopes: [], missing_scopes: []}}
        )

        Plug.Conn.send_resp(conn, 503, "unavailable")
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer rotated"]
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, %{status: 200}} =
               Request.request(:get, "https://test.local", ref, plug: {Req.Test, __MODULE__})

      assert Enum.count(Client.calls(), fn {op, _} -> op == :vend_credentials end) == 2
    end

    test "API keys use the descriptor's header and graph options cannot replace auth", %{ref: ref} do
      Client.put_response(
        :vend_credentials,
        {:ok, %{auth_method: "api_key", value: "key_123", scopes: [], missing_scopes: []}}
      )

      Req.Test.expect(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["key_123"]
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, %{status: 200}} =
               Request.request(:get, "https://test.local", ref,
                 plug: {Req.Test, __MODULE__},
                 headers: [{"authorization", "forged"}],
                 url: "https://evil.test",
                 redirect: true
               )
    end
  end
end
