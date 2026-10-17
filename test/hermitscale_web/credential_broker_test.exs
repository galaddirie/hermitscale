defmodule HermitscaleWeb.CredentialBrokerTest do
  use HermitscaleWeb.ConnCase, async: false

  import Hermitscale.AccountsFixtures
  import Hermitscale.CredentialBrokerFixtures
  import Hermitscale.WorkspacesFixtures

  alias Hermitscale.CredentialBroker
  alias Hermitscale.WorkOSTest

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}
  setup :stub_broker_clients

  setup do
    previous = Application.get_env(:hermitscale, CredentialBroker)

    Application.put_env(:hermitscale, CredentialBroker,
      req_options: [plug: {Req.Test, __MODULE__}, retry_delay: 0]
    )

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:hermitscale, CredentialBroker)
        value -> Application.put_env(:hermitscale, CredentialBroker, value)
      end
    end)

    scope = user_scope_fixture()
    workspace = workspace_fixture(scope)
    {:ok, secret, token} = CredentialBroker.issue_token(scope, workspace)
    %{scope: scope, workspace: workspace, secret: secret, token: token}
  end

  describe "API requests" do
    setup %{scope: scope, workspace: workspace} do
      grant_fixture(scope, workspace, ["* /items/*"], "test.credentials")
      :ok
    end

    test "forward with the vended credential and no caller credentials", %{
      conn: conn,
      secret: secret,
      token: token
    } do
      events =
        :telemetry_test.attach_event_handlers(self(), [
          [:hermitscale, :credential_broker, :request]
        ])

      Req.Test.expect(__MODULE__, fn upstream ->
        assert upstream.host == "test.local"
        assert {upstream.method, upstream.request_path} == {"POST", "/items/1"}
        assert upstream.query_string == "q=1"
        assert {:ok, ~s({"a":1}), upstream} = Plug.Conn.read_body(upstream)

        headers = Map.new(upstream.req_headers)
        assert headers["authorization"] == "Bearer access_123"
        assert headers["content-type"] == "application/json"
        assert headers["x-custom"] == "kept"
        refute Map.has_key?(headers, "cookie")
        refute Map.has_key?(headers, "x-forwarded-for")
        refute Enum.any?(Map.values(headers), &(&1 =~ secret))

        upstream
        |> Plug.Conn.put_resp_header("set-cookie", "provider=1")
        |> Plug.Conn.put_resp_header("x-provider", "yes")
        |> Plug.Conn.send_resp(201, ~s({"token":"access_123"}))
      end)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> secret)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("cookie", "_hermitscale_key=session")
        |> put_req_header("x-forwarded-for", "1.2.3.4")
        |> put_req_header("x-custom", "kept")
        |> post("/broker/v1/api/test.credentials/items/1?q=1", ~s({"a":1}))

      assert conn.status == 201
      assert conn.resp_body == ~s({"token":"[REDACTED]"})
      assert get_resp_header(conn, "x-provider") == ["yes"]
      assert get_resp_header(conn, "set-cookie") == []

      token_id = token.id

      assert_received {[:hermitscale, :credential_broker, :request], ^events, %{status: 201},
                       %{token_id: ^token_id, method: "POST", path: "/items/1"}}
    end

    test "reject missing tokens, other paths, and ungranted providers", %{
      conn: conn,
      secret: secret
    } do
      conn = get(conn, "/broker/v1/api/test.credentials/items/1")
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="Hermitscale broker")]

      authed = put_req_header(build_conn(), "authorization", "Bearer " <> secret)

      assert json_response(get(authed, "/broker/v1/api/test.credentials/admin"), 403) ==
               %{"error" => "endpoint_not_allowed"}

      assert json_response(get(authed, "/broker/v1/api/github/user"), 403) ==
               %{"error" => "not_granted"}

      assert json_response(get(authed, "/broker/v1/api/test.credentials/items/a%2F..%2Fb"), 400) ==
               %{"error" => "invalid_path"}

      assert json_response(get(authed, "/broker/v1/elsewhere"), 404) == %{"error" => "not_found"}

      refute Enum.any?(WorkOSTest.Client.calls(), &match?({:vend_credentials, _args}, &1))
    end

    test "match rules on the decoded path and encode it once upstream", %{
      conn: conn,
      secret: secret
    } do
      Req.Test.expect(__MODULE__, fn upstream ->
        assert upstream.request_path == "/items/a%20b%3Ac"
        Plug.Conn.send_resp(upstream, 200, "ok")
      end)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> secret)
        |> get("/broker/v1/api/test.credentials/items/a%20b:c")

      assert conn.resp_body == "ok"
    end

    test "re-check the acting member before vending", %{conn: conn, secret: secret} do
      WorkOSTest.Client.put_response(:list_memberships, {:ok, %{"data" => []}})

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> secret)
        |> get("/broker/v1/api/test.credentials/items/1")

      assert json_response(conn, 403) == %{"error" => "execution_actor_ineligible"}
      refute Enum.any?(WorkOSTest.Client.calls(), &match?({:vend_credentials, _args}, &1))
    end
  end

  describe "Git requests" do
    setup %{scope: scope, workspace: workspace} do
      grant_fixture(scope, workspace, ["FETCH /acme/web"])
      :ok
    end

    test "proxy fetches with the token as a Basic password", %{conn: conn, secret: secret} do
      Req.Test.expect(__MODULE__, fn upstream ->
        assert upstream.host == "github.com"
        assert upstream.request_path == "/acme/web.git/info/refs"
        assert upstream.query_string == "service=git-upload-pack"

        assert Plug.Conn.get_req_header(upstream, "authorization") ==
                 ["Basic " <> Base.encode64("x-access-token:access_123")]

        assert Plug.Conn.get_req_header(upstream, "git-protocol") == ["version=2"]

        upstream
        |> Plug.Conn.put_resp_content_type("application/x-git-upload-pack-advertisement", nil)
        |> Plug.Conn.send_resp(200, "001e# service=git-upload-pack\n")
      end)

      conn =
        conn
        |> put_req_header("authorization", "Basic " <> Base.encode64("x:" <> secret))
        |> put_req_header("git-protocol", "version=2")
        |> get("/broker/v1/git/github/acme/web.git/info/refs?service=git-upload-pack")

      assert conn.status == 200
      assert conn.resp_body == "001e# service=git-upload-pack\n"

      Req.Test.expect(__MODULE__, fn upstream ->
        assert {upstream.method, upstream.request_path} == {"POST", "/acme/web/git-upload-pack"}
        assert {:ok, "0032want", _upstream} = Plug.Conn.read_body(upstream)
        Plug.Conn.send_resp(upstream, 200, "PACK")
      end)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> secret)
        |> put_req_header("content-type", "application/x-git-upload-pack-request")
        |> post("/broker/v1/git/github/acme/web/git-upload-pack", "0032want")

      assert conn.resp_body == "PACK"
    end

    test "check pushes separately and reject other Git paths", %{conn: conn, secret: secret} do
      authed =
        conn
        |> put_req_header("authorization", "Bearer " <> secret)
        |> put_req_header("content-type", "application/x-git-receive-pack-request")

      assert json_response(
               get(
                 authed,
                 "/broker/v1/git/github/acme/web.git/info/refs?service=git-receive-pack"
               ),
               403
             ) == %{"error" => "endpoint_not_allowed"}

      assert json_response(
               post(authed, "/broker/v1/git/github/acme/web.git/git-receive-pack", ""),
               403
             ) ==
               %{"error" => "endpoint_not_allowed"}

      assert json_response(get(authed, "/broker/v1/git/github/acme/web.git/HEAD"), 404) ==
               %{"error" => "not_found"}

      assert json_response(
               get(
                 authed,
                 "/broker/v1/git/github/acme/other.git/info/refs?service=git-upload-pack"
               ),
               403
             ) == %{"error" => "endpoint_not_allowed"}

      conn =
        get(build_conn(), "/broker/v1/git/github/acme/web.git/info/refs?service=git-upload-pack")

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="Hermitscale broker")]
    end
  end
end
