defmodule Hermitscale.Workspaces.SpritesClientTest do
  use ExUnit.Case, async: false

  alias Hermitscale.Workspaces.SpritesClient

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    previous = Application.get_env(:hermitscale, SpritesClient)

    Application.put_env(:hermitscale, SpritesClient,
      token: "sprites-test-secret",
      base_url: "https://api.sprites.test",
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:hermitscale, SpritesClient)
        config -> Application.put_env(:hermitscale, SpritesClient, config)
      end
    end)
  end

  describe "REST" do
    test "creates, gets, and deletes Sprites with the configured token" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/v1/sprites"}
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sprites-test-secret"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"name" => "hs-one"}
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"name" => "hs-one"})
      end)

      assert {:ok, %{"name" => "hs-one"}} = SpritesClient.create("hs-one")

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/sprites/hs%2Fone"
        Req.Test.json(conn, %{"status" => "warm"})
      end)

      assert {:ok, %{"status" => "warm"}} = SpritesClient.get("hs/one")

      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 404, "gone"))
      assert :ok = SpritesClient.delete("hs-one")
    end

    test "gets and sets the network policy" do
      rules = [%{"include" => "defaults"}, %{"domain" => "*", "action" => "deny"}]

      Req.Test.expect(__MODULE__, fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/v1/sprites/hs-one/policy/network"}
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"rules" => rules}
        Req.Test.json(conn, %{"rules" => rules})
      end)

      assert {:ok, %{"rules" => ^rules}} = SpritesClient.put_network_policy("hs-one", rules)

      Req.Test.expect(__MODULE__, fn conn ->
        assert {conn.method, conn.request_path} == {"GET", "/v1/sprites/hs-one/policy/network"}
        Req.Test.json(conn, %{"rules" => rules})
      end)

      assert {:ok, %{"rules" => ^rules}} = SpritesClient.get_network_policy("hs-one")
    end

    test "maps non-2xx responses without retrying" do
      for {status, reason} <- [
            {404, :not_found},
            {409, :conflict},
            {503, {:http_error, 503, "unavailable"}}
          ] do
        Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, status, "unavailable"))
        assert {:error, ^reason} = SpritesClient.get("hs-one")
      end
    end

    test "reads and writes raw file bytes" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/v1/sprites/hs-one/fs/write"

        assert Plug.Conn.fetch_query_params(conn).query_params == %{
                 "path" => "/a",
                 "mkdir" => "true"
               }

        assert {:ok, <<0, 255>>, conn} = Plug.Conn.read_body(conn)
        Req.Test.json(conn, %{"path" => "/a"})
      end)

      assert {:ok, %{"path" => "/a"}} =
               SpritesClient.write_file("hs-one", "/a", <<0, 255>>, mkdir: true)

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "{\"raw\":true}")
      end)

      assert {:ok, "{\"raw\":true}"} = SpritesClient.read_file("hs-one", "/a.json")
    end

    test "returns checkpoint progress and reports streamed errors" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/sprites/hs-one/checkpoint"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"comment" => "before"}
        ndjson(conn, [%{"type" => "info"}, %{"type" => "complete", "data" => "v1"}])
      end)

      assert {:ok, [%{"type" => "info"}, %{"type" => "complete"}]} =
               SpritesClient.create_checkpoint("hs-one", comment: "before")

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/sprites/hs-one/checkpoints/v1/restore"
        ndjson(conn, [%{"type" => "error", "error" => "nope"}])
      end)

      assert {:error, {:operation_failed, %{"error" => "nope"}}} =
               SpritesClient.restore_checkpoint("hs-one", "v1")
    end

    test "lists and kills sessions" do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"sessions" => [%{"id" => 7}]}))
      assert {:ok, [%{"id" => 7}]} = SpritesClient.list_sessions("hs-one")

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/sprites/hs-one/exec/7/kill"
        assert Plug.Conn.fetch_query_params(conn).query_params == %{"signal" => "SIGTERM"}
        ndjson(conn, [%{"type" => "complete"}])
      end)

      assert {:ok, [%{"type" => "complete"}]} =
               SpritesClient.kill_session("hs-one", 7, signal: "SIGTERM")
    end

    test "manages services and URL settings" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert {conn.method, conn.request_path} == {"PUT", "/v1/sprites/hs-one/services/web"}
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Req.Test.json(conn, Jason.decode!(body))
      end)

      assert {:ok, %{"cmd" => "server"}} =
               SpritesClient.put_service("hs-one", "web", %{cmd: "server"})

      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 204, ""))
      assert :ok = SpritesClient.delete_service("hs-one", "web")

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"url_settings" => %{"auth" => "public"}}
        Req.Test.json(conn, %{})
      end)

      assert {:ok, %{}} = SpritesClient.update_url_settings("hs-one", %{auth: "public"})
    end
  end

  describe "commands" do
    setup do
      server =
        start_supervised!(
          {Bandit,
           plug: {Hermitscale.WorkspacesTest.SpritesPlug, test_pid: self()},
           port: 0,
           ip: {127, 0, 0, 1},
           startup_log: false}
        )

      {:ok, {_address, port}} = ThousandIsland.listener_info(server)

      Application.put_env(:hermitscale, SpritesClient,
        token: "sprites-test-secret",
        base_url: "http://127.0.0.1:#{port}"
      )

      %{task_supervisor: start_supervised!(Task.Supervisor)}
    end

    test "streams output and stdin without exposing the token" do
      assert {:ok, command} =
               SpritesClient.spawn("hs-one", "bash", ["-lc", "script"],
                 dir: "/root",
                 env: [{"CUSTOM", "value"}],
                 session_info: true,
                 stdin: true
               )

      refute inspect(command) =~ "sprites-test-secret"

      assert_receive {:sprites_socket, socket, "/v1/sprites/hs-one/exec", query,
                      ["Bearer sprites-test-secret"]}

      assert for({"cmd", arg} <- query, do: arg) == ["bash", "-lc", "script"]
      assert {"dir", "/root"} in query
      assert {"env", "CUSTOM=value"} in query

      assert :ok = Sprites.write(command, "input\n")
      assert_receive {:sprites_input, :binary, <<0, "input\n">>}

      send(
        socket,
        {:frames,
         [
           {:text, Jason.encode!(%{type: "session_info", session_id: "1847"})},
           {:binary, <<1, "out">>},
           {:binary, <<2, "err">>},
           {:binary, <<3, 7>>}
         ]}
      )

      ref = command.ref
      assert_receive {:session_info, %{ref: ^ref}, "1847"}
      assert_receive {:stdout, %{ref: ^ref}, "out"}
      assert_receive {:stderr, %{ref: ^ref}, "err"}
      assert_receive {:exit, %{ref: ^ref}, 7}
    end

    test "execute collects output and exit code", %{task_supervisor: task_supervisor} do
      task =
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          SpritesClient.execute("hs-one", "bash", ["-lc", "script"])
        end)

      assert_receive {:sprites_socket, socket, _path, _query, _auth}

      send(
        socket,
        {:frames,
         [
           {:binary, <<1, "one">>},
           {:binary, <<1, "two">>},
           {:binary, <<2, "warn">>},
           {:binary, <<3, 7>>}
         ]}
      )

      assert {:ok, %{stdout: "onetwo", stderr: "warn", exit_code: 7}} = Task.await(task)
    end

    test "execute stops the command on timeout" do
      assert {:error, :timeout} = SpritesClient.execute("hs-one", "bash", [], timeout: 0)
      assert_receive {:sprites_socket_closed, _reason}
    end

    test "closes the transport when the owner exits", %{task_supervisor: task_supervisor} do
      test_pid = self()

      task =
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          {:ok, command} = SpritesClient.spawn("hs-one", "bash")
          send(test_pid, {:command, command})
          receive do: (:finish -> :ok)
        end)

      assert_receive {:command, command}
      assert_receive {:sprites_socket, _socket, _path, _query, _auth}
      monitor = Process.monitor(command.pid)
      send(task.pid, :finish)
      assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
      assert_receive {:sprites_socket_closed, _reason}
    end
  end

  defp ndjson(conn, messages) do
    conn
    |> Plug.Conn.put_resp_content_type("application/x-ndjson")
    |> Plug.Conn.send_resp(200, Enum.map_join(messages, "\n", &Jason.encode!/1))
  end
end
