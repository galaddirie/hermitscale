defmodule Hermitscale.Credentials.Backends.WorkOSTest do
  use ExUnit.Case, async: false
  use Hermitscale.Credentials.BackendCase

  alias Hermitscale.Credentials.AccessToken
  alias Hermitscale.Credentials.Backends.WorkOS

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    previous = Application.get_env(:hermitscale, WorkOS)

    Application.put_env(:hermitscale, WorkOS,
      api_key: "sk_test_123",
      client_id: "client_test_123",
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:hermitscale, WorkOS)
        previous -> Application.put_env(:hermitscale, WorkOS, previous)
      end
    end)

    {:ok, store} = Agent.start_link(fn -> %{} end)
    Req.Test.stub(__MODULE__, vault_stub(store))

    ctx = %{
      credential_id: Ecto.UUID.generate(),
      provider: "github",
      org_id: "org_test",
      user_id: nil,
      external_ref: nil
    }

    %{backend: WorkOS, backend_ctx: ctx, store: store}
  end

  describe "managed OAuth (Pipes)" do
    test "get_oauth_token returns a fresh access token", %{backend_ctx: ctx} do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/pipes/v1/tokens"
        assert {"authorization", "Bearer sk_test_123"} in conn.req_headers

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"connection_id" => "conn_123"} = Jason.decode!(body)

        Req.Test.json(conn, %{"access_token" => "pipes_token", "expires_in" => 300})
      end)

      assert {:ok, %AccessToken{access_token: "pipes_token", expires_at: %DateTime{}}} =
               WorkOS.get_oauth_token("conn_123", ctx)
    end

    test "a reauthorization body code maps to :reauth_required", %{backend_ctx: ctx} do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(422, Jason.encode!(%{"code" => "reauthorization_required"}))
      end)

      assert {:error, :reauth_required} = WorkOS.get_oauth_token("conn_123", ctx)
    end

    test "an unknown connection maps to :reauth_required", %{backend_ctx: ctx} do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"code" => "not_found"}))
      end)

      assert {:error, :reauth_required} = WorkOS.get_oauth_token("conn_gone", ctx)
    end

    test "connect_config returns widget configuration", %{backend_ctx: ctx} do
      assert {:ok, config} = WorkOS.connect_config("github", ctx)
      assert config.type == "workos_pipes_widget"
      assert config.provider == "github"
      assert config.client_id == "client_test_123"
      assert config.context.credential_id == ctx.credential_id
    end

    test "disconnect is idempotent on 404", %{backend_ctx: ctx} do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/pipes/v1/connections/conn_123"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, "{}")
      end)

      assert :ok = WorkOS.disconnect("conn_123", ctx)
    end
  end

  # In-memory fake of the Vault kv API, enough for the conformance suite.
  defp vault_stub(store) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case {conn.method, Path.split(conn.request_path)} do
        {"POST", ["/", "vault", "v1", "kv"]} ->
          %{"value" => value} = Jason.decode!(body)
          object_id = "obj_#{System.unique_integer([:positive])}"
          Agent.update(store, &Map.put(&1, object_id, value))
          Req.Test.json(conn, %{"id" => object_id})

        {"GET", ["/", "vault", "v1", "kv", object_id]} ->
          case Agent.get(store, &Map.get(&1, object_id)) do
            nil -> not_found(conn)
            value -> Req.Test.json(conn, %{"id" => object_id, "value" => value})
          end

        {"PUT", ["/", "vault", "v1", "kv", object_id]} ->
          if Agent.get(store, &Map.has_key?(&1, object_id)) do
            %{"value" => value} = Jason.decode!(body)
            Agent.update(store, &Map.put(&1, object_id, value))
            Req.Test.json(conn, %{"id" => object_id})
          else
            not_found(conn)
          end

        {"DELETE", ["/", "vault", "v1", "kv", object_id]} ->
          Agent.update(store, &Map.delete(&1, object_id))
          Req.Test.json(conn, %{})
      end
    end
  end

  defp not_found(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(404, Jason.encode!(%{"code" => "not_found"}))
  end
end
