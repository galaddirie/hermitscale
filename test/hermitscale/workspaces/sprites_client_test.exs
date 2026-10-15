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

    :ok
  end

  describe "sprite lifecycle" do
    test "creates a private sprite and returns provider metadata" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/sprites"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sprites-test-secret"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "name" => "workspace-one",
                 "url_settings" => %{"auth" => "sprite"}
               }

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(sprite_metadata("workspace-one"))
      end)

      assert {:ok, %{"id" => "sprite-id", "name" => "workspace-one", "status" => "cold"}} =
               SpritesClient.create("workspace-one")
    end

    test "gets a Sprite by encoded name, rejects mismatched metadata, and deletes idempotently" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/sprites/workspace%2Fone"
        Req.Test.json(conn, sprite_metadata("workspace/one"))
      end)

      assert {:ok, %{"name" => "workspace/one"}} = SpritesClient.get("workspace/one")

      Req.Test.expect(__MODULE__, &Req.Test.json(&1, sprite_metadata("someone-else")))
      assert {:error, :invalid_response} = SpritesClient.get("workspace-one")

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/v1/sprites/workspace-one"
        Plug.Conn.send_resp(conn, 404, "already deleted")
      end)

      assert :ok = SpritesClient.delete("workspace-one")
    end

    test "never retries mutations, redirects credentials, or exposes provider error bodies" do
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 503, "sprites-test-secret"))
      assert {:error, :unavailable} = SpritesClient.create("workspace-one")

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://untrusted.example")
        |> Plug.Conn.send_resp(302, "sprites-test-secret")
      end)

      assert {:error, {:unexpected_status, 302}} = SpritesClient.get("workspace-one")

      for {status, reason} <- [
            {401, :unauthorized},
            {403, :forbidden},
            {404, :not_found},
            {409, :conflict},
            {429, :rate_limited}
          ] do
        Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, status, "sprites-test-secret"))
        assert {:error, ^reason} = SpritesClient.get("workspace-one")
      end
    end

    test "requires credentials and ignores caller connection overrides" do
      Application.put_env(:hermitscale, SpritesClient, [])
      assert {:error, :not_configured} = SpritesClient.create("workspace-one")

      Application.put_env(:hermitscale, SpritesClient,
        token: "sprites-test-secret",
        base_url: "https://api.sprites.test",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.host == "api.sprites.test"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sprites-test-secret"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        refute Map.has_key?(Jason.decode!(body), "token")
        Req.Test.json(conn, sprite_metadata("workspace-one"))
      end)

      assert {:ok, _sprite} =
               SpritesClient.create("workspace-one",
                 token: "evil",
                 base_url: "https://untrusted.example",
                 req_options: [redirect: true]
               )
    end
  end

  describe "filesystem" do
    test "reads raw bytes, lists entries, writes bytes, and deletes paths without local access" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/sprites/workspace-one/fs/read"
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params == %{"path" => "../secret.bin", "workingDir" => "/home/sprite"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, <<0, 255, 1>>)
      end)

      assert {:ok, <<0, 255, 1>>} =
               SpritesClient.read_file("workspace-one", "../secret.bin",
                 working_dir: "/home/sprite"
               )

      entry = %{"name" => "secret.bin", "path" => "/secret.bin", "isDir" => false, "size" => 3}

      Req.Test.expect(
        __MODULE__,
        &Req.Test.json(&1, %{"entries" => [entry], "path" => "/", "count" => 1})
      )

      assert {:ok, %{"entries" => [^entry]}} = SpritesClient.list_files("workspace-one", "/")

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/v1/sprites/workspace-one/fs/write"
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.query_params == %{
                 "path" => "/app/data.bin",
                 "workingDir" => "/",
                 "mode" => "0600",
                 "mkdir" => "true"
               }

        {:ok, <<0, 255, 1>>, conn} = Plug.Conn.read_body(conn)
        Req.Test.json(conn, %{"path" => "/app/data.bin", "size" => 3, "mode" => "0600"})
      end)

      assert {:ok, %{"size" => 3}} =
               SpritesClient.write_file("workspace-one", "/app/data.bin", <<0, 255, 1>>,
                 mode: "0600",
                 mkdir: true
               )

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/v1/sprites/workspace-one/fs/delete"
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "path" => "/app",
                 "workingDir" => "/",
                 "recursive" => true,
                 "asRoot" => true
               }

        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      assert :ok =
               SpritesClient.delete_file("workspace-one", "/app", recursive: true, as_root: true)
    end

    test "rejects malformed listing and write metadata and propagates missing files" do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"entries" => "not-a-list"}))
      assert {:error, :invalid_response} = SpritesClient.list_files("workspace-one", "/")
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"size" => -1}))

      assert {:error, :invalid_response} =
               SpritesClient.write_file("workspace-one", "/file", "data")

      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 404, "sprites-test-secret"))
      assert {:error, :not_found} = SpritesClient.read_file("workspace-one", "/missing")
    end
  end

  describe "checkpoints and services" do
    test "requires checkpoint completion and returns progress with provider checkpoint IDs" do
      checkpoint = %{"id" => "v5", "comment" => "Before changes"}
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, [checkpoint]))
      assert {:ok, [^checkpoint]} = SpritesClient.list_checkpoints("workspace-one")

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/sprites/workspace-one/checkpoint"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"comment" => "Before changes"}

        ndjson(conn, [
          %{"type" => "info", "data" => "Saving"},
          %{"type" => "complete", "data" => "v5"}
        ])
      end)

      assert {:ok, [%{"type" => "info"}, %{"type" => "complete", "data" => "v5"}]} =
               SpritesClient.create_checkpoint("workspace-one", comment: "Before changes")

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/sprites/workspace-one/checkpoints/v5%2Frestore/restore"
        ndjson(conn, [%{"type" => "error", "data" => "sprites-test-secret"}])
      end)

      assert {:error, :operation_failed} =
               SpritesClient.restore_checkpoint("workspace-one", "v5/restore")

      Req.Test.expect(__MODULE__, &ndjson(&1, [%{"type" => "info", "data" => "unfinished"}]))
      assert {:error, :invalid_response} = SpritesClient.create_checkpoint("workspace-one")
    end

    test "lists services, writes their definitions, deletes them, and changes URL access" do
      service = %{
        "name" => "web",
        "cmd" => "bash",
        "args" => ["-lc", "python -m http.server 8080"],
        "needs" => []
      }

      Req.Test.expect(__MODULE__, &Req.Test.json(&1, [service]))
      assert {:ok, [^service]} = SpritesClient.list_services("workspace-one")

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/sprites/workspace-one/services/web%2Fapp"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == service
        Req.Test.json(conn, Map.put(service, "name", "web/app"))
      end)

      assert {:ok, %{"name" => "web/app"}} =
               SpritesClient.put_service("workspace-one", "web/app", service)

      Req.Test.expect(__MODULE__, &Req.Test.json(&1, service))
      assert {:ok, ^service} = SpritesClient.get_service("workspace-one", "web")
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 204, ""))
      assert :ok = SpritesClient.delete_service("workspace-one", "web")

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/v1/sprites/workspace-one"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"url_settings" => %{"auth" => "public"}}
        Req.Test.json(conn, sprite_metadata("workspace-one"))
      end)

      assert {:ok, %{"name" => "workspace-one"}} =
               SpritesClient.update_url_settings("workspace-one", %{auth: "public"})
    end

    test "accepts streamed service startup only after completion and rejects malformed resources" do
      Req.Test.expect(__MODULE__, &ndjson(&1, [%{"type" => "complete", "data" => "Started"}]))
      service = %{"name" => "web", "cmd" => "python", "args" => [], "needs" => []}
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, service))
      assert {:ok, ^service} = SpritesClient.put_service("workspace-one", "web", service)

      for callback <- [
            fn -> SpritesClient.list_checkpoints("workspace-one") end,
            fn -> SpritesClient.list_services("workspace-one") end,
            fn -> SpritesClient.get_service("workspace-one", "web") end
          ] do
        Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"unexpected" => "sprites-test-secret"}))
        assert {:error, :invalid_response} = callback.()
      end
    end

    test "lists detached sessions and kills only the selected session with completed progress" do
      session = %{"id" => 1847, "command" => "bash", "tty" => true}
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"sessions" => [session], "count" => 1}))
      assert {:ok, [^session]} = SpritesClient.list_sessions("workspace-one")

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/sprites/workspace-one/exec/1847/kill"
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params == %{"signal" => "SIGTERM", "timeout" => "10s"}
        ndjson(conn, [%{"type" => "complete", "data" => "Killed"}])
      end)

      assert {:ok, [%{"type" => "complete"}]} =
               SpritesClient.kill_session("workspace-one", 1847,
                 signal: "SIGTERM",
                 timeout: "10s"
               )

      Req.Test.expect(
        __MODULE__,
        &ndjson(&1, [%{"type" => "error", "data" => "sprites-test-secret"}])
      )

      assert {:error, :operation_failed} = SpritesClient.kill_session("workspace-one", "1847")
    end
  end

  describe "WebSocket commands" do
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

    test "streams split stdout, stderr and stdin through the official SDK without exposing credentials" do
      assert {:ok, command} =
               SpritesClient.spawn("workspace-one", "bash", ["-lc", "arbitrary script"],
                 dir: "/root",
                 env: [{"CUSTOM", "value"}],
                 session_info: true,
                 stdin: true
               )

      assert command.sprite == nil
      refute inspect(command) =~ "sprites-test-secret"

      assert_receive {:sprites_socket, socket, "/v1/sprites/workspace-one/exec", query,
                      ["Bearer sprites-test-secret"]}

      assert Enum.filter(query, &(elem(&1, 0) == "cmd")) == [
               {"cmd", "bash"},
               {"cmd", "-lc"},
               {"cmd", "arbitrary script"}
             ]

      assert {"dir", "/root"} in query
      assert {"env", "CUSTOM=value"} in query
      assert {"stdin", "true"} in query

      assert :ok = Sprites.write(command, "input\n")
      assert_receive {:sprites_input, :binary, <<0, "input\n">>}

      send(
        socket,
        {:frames,
         [
           {:text, Jason.encode!(%{type: "session_info", session_id: "1847"})},
           {:binary, <<1, "one">>},
           {:binary, <<1, "two">>},
           {:binary, <<2, "warning">>},
           {:binary, <<3, 7>>}
         ]}
      )

      ref = command.ref
      assert_receive {:session_info, %{ref: ^ref}, "1847"}
      assert_receive {:stdout, %{ref: ^ref}, "one"}
      assert_receive {:stdout, %{ref: ^ref}, "two"}
      assert_receive {:stderr, %{ref: ^ref}, "warning"}
      assert_receive {:exit, %{ref: ^ref}, 7}
    end

    test "captures separate output and nonzero status and forces its own owner", %{
      task_supervisor: task_supervisor
    } do
      other_owner = self()

      task =
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          SpritesClient.execute("workspace-one", "bash", ["-lc", "arbitrary"], owner: other_owner)
        end)

      assert_receive {:sprites_socket, socket, _path, _query, _auth}

      send(
        socket,
        {:frames,
         [
           {:binary, <<1, "one">>},
           {:binary, <<1, "two">>},
           {:binary, <<2, "warning">>},
           {:binary, <<3, 7>>}
         ]}
      )

      assert {:ok, %{stdout: "onetwo", stderr: "warning", exit_code: 7}} = Task.await(task)
    end

    test "allows explicit local timeout and reports malformed terminal metadata", %{
      task_supervisor: task_supervisor
    } do
      assert {:error, :invalid_timeout} =
               SpritesClient.execute("workspace-one", "bash", [], timeout: "invalid")

      refute_receive {:sprites_socket, _socket, _path, _query, _auth}
      assert {:error, :timeout} = SpritesClient.execute("workspace-one", "bash", [], timeout: 0)
      assert_receive {:sprites_socket, _socket, _path, _query, _auth}
      assert_receive {:sprites_socket_closed, _reason}

      task =
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          SpritesClient.execute("workspace-one", "bash")
        end)

      assert_receive {:sprites_socket, socket, _path, _query, _auth}

      send(
        socket,
        {:frames, [{:text, Jason.encode!(%{type: "exit", exit_code: "sprites-test-secret"})}]}
      )

      assert {:error, :invalid_response} = Task.await(task)
    end

    test "attaches to a valid numeric provider ID with TTY and stdin controls" do
      assert {:ok, command} = SpritesClient.attach_session("workspace-one", 1847, stdin: true)

      assert_receive {:sprites_socket, socket, "/v1/sprites/workspace-one/exec/1847", query,
                      _auth}

      assert {"tty", "true"} in query
      assert {"stdin", "true"} in query
      refute List.keymember?(query, "cmd", 0)
      assert :ok = Sprites.resize(command, 40, 120)
      assert_receive {:sprites_input, :text, resize_json}
      assert Jason.decode!(resize_json) == %{"type" => "resize", "rows" => 40, "cols" => 120}
      send(socket, {:frames, [{:text, Jason.encode!(%{type: "exit", exit_code: 0})}]})
      ref = command.ref
      assert_receive {:exit, %{ref: ^ref}, 0}
    end

    test "closes the SDK transport when its owner dies", %{task_supervisor: task_supervisor} do
      test_pid = self()

      task =
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          {:ok, command} = SpritesClient.spawn("workspace-one", "bash", [], detachable: true)
          send(test_pid, {:owned_command, command})

          receive do
            :finish -> :ok
          end
        end)

      assert_receive {:owned_command, command}
      assert_receive {:sprites_socket, _socket, _path, _query, _auth}
      monitor = Process.monitor(command.pid)
      assert :ok = Task.Supervisor.terminate_child(task_supervisor, task.pid)
      assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
      assert_receive {:sprites_socket_closed, _reason}
    end

    test "reports unexpected SDK death instead of hanging or leaking secrets" do
      assert {:ok, command} = SpritesClient.spawn("workspace-one", "bash")
      assert_receive {:sprites_socket, _socket, _path, _query, _auth}
      Process.exit(command.pid, :kill)
      ref = command.ref
      assert_receive {:error, %{ref: ^ref}, :unavailable}
      assert {:error, :forbidden} = SpritesClient.spawn("workspace-one", "rejected")
    end

    test "rejects attach IDs that could escape the provider's path" do
      assert {:error, :invalid_session_id} =
               SpritesClient.attach_session("workspace-one", "../../other/exec")

      assert {:error, :invalid_session_id} =
               SpritesClient.spawn("workspace-one", "bash", [], session_id: "../other")
    end
  end

  defp ndjson(conn, messages) do
    body = Enum.map_join(messages, "\n", &Jason.encode!/1) <> "\n"

    conn
    |> Plug.Conn.put_resp_content_type("application/x-ndjson")
    |> Plug.Conn.send_resp(200, body)
  end

  defp sprite_metadata(name) do
    %{
      "id" => "sprite-id",
      "name" => name,
      "status" => "cold",
      "url" => "https://workspace-one.sprites.app",
      "organization" => "fly-org"
    }
  end
end
