defmodule Hermitscale.WorkspaceWorker.ControlTest do
  use ExUnit.Case, async: true

  alias Hermitscale.WorkspaceProtocol.V1, as: Protocol
  alias Hermitscale.WorkspaceWorker.{Control, FixtureAdapter, Journal, Runtime}

  setup do
    directory = Path.join("/tmp", "hw-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(directory) end)
    tasks = start_supervised!({Task.Supervisor, []})

    journal =
      start_supervised!(
        {Journal, path: Path.join(directory, "journal"), workspace_id: "workspace_fixture"}
      )

    runtime =
      start_supervised!(
        {Runtime,
         journal: journal,
         adapter: FixtureAdapter,
         activity_adapter: FixtureAdapter,
         config: [receiver: self()]}
      )

    path = Path.join(directory, "control.sock")
    token = String.duplicate("t", 32)

    control_options = [
      runtime: runtime,
      tasks: tasks,
      socket_path: path,
      control_token: token,
      token_deadline: ~U[2099-01-01 00:00:00Z]
    ]

    start_supervised!({Control, control_options})
    %{path: path, token: token, journal: journal, options: control_options}
  end

  test "bidirectional socket requests reconnect without starting the accepted provider twice",
       context do
    start = fixture()
    assert %{"ok" => true, "result" => %{"status" => "accepted"}} = request(context, start)
    assert_receive {:fixture_started, "operation_fixture"}
    assert %{"ok" => true, "result" => %{"status" => "running"}} = request(context, start)
    refute_receive {:fixture_started, _operation}
    epoch = Journal.epoch(context.journal)
    read = command("read_events", "read", %{"epoch" => epoch, "cursor" => 0, "limit" => 100})

    assert %{
             "ok" => true,
             "result" => %{"events" => [%{"type" => "accepted"}, %{"type" => "running"}]}
           } = request(context, read)

    assert %{
             "ok" => true,
             "result" => %{"termination_confirmed" => true, "status" => "interrupted"}
           } =
             request(context, command("cancel", "cancel", %{}))

    assert_receive :fixture_cancel_requested
  end

  test "bad credentials and expired command deadlines never start model work", context do
    assert %{"ok" => false, "error" => "unauthorized_or_invalid_frame"} =
             request(%{context | token: String.duplicate("x", 32)}, fixture())

    expired = %{fixture() | "deadline" => "2000-01-01T00:00:00Z"}
    assert %{"ok" => false, "error" => "deadline_expired"} = request(context, expired)
    assert {:error, :operation_not_found} = Journal.status(context.journal, "operation_fixture")
    refute_receive {:fixture_started, _operation}
  end

  test "expired transport authority rejects even a valid command", context do
    :ok = stop_supervised(Control)

    start_supervised!(
      {Control, Keyword.put(context.options, :token_deadline, ~U[2000-01-01 00:00:00Z])}
    )

    assert %{"ok" => false, "error" => "unauthorized_or_invalid_frame"} =
             request(context, fixture())

    refute_receive {:fixture_started, _operation}
  end

  defp request(context, command) do
    {:ok, socket} =
      :gen_tcp.connect(
        {:local, String.to_charlist(context.path)},
        0,
        [:binary, active: false, packet: 4],
        5_000
      )

    :ok = :gen_tcp.send(socket, JSON.encode!(%{"token" => context.token, "command" => command}))
    {:ok, result} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    JSON.decode!(result)
  end

  defp fixture,
    do:
      Path.expand("../../priv/workspace_protocol/v1/fixtures/start.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()

  defp command(type, command_id, payload) do
    fixture()
    |> Map.merge(%{
      "type" => type,
      "command_id" => command_id,
      "payload" => payload,
      "payload_digest" => Protocol.payload_digest(payload)
    })
  end
end
