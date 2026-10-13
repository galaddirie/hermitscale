defmodule Hermitscale.WorkspaceWorker.HarnessTest do
  use ExUnit.Case, async: true

  alias Hermitscale.WorkspaceWorker.{FixtureSession, Harness}

  test "pinned session contract initializes before input, replays sequence cursor, and interrupts the exact turn" do
    command =
      Path.expand("../../priv/workspace_protocol/v1/fixtures/start.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()

    config = [
      cwd: "/workspace",
      acp_path: "/opt/bin/codex-acp",
      env: %{"PATH" => "/opt/bin", "OPENAI_API_KEY" => "fixture-key"},
      session_api: FixtureSession,
      process_api: FixtureSession
    ]

    Process.put(:fixture_initializing, true)
    assert {:ok, handle} = Harness.start(command, config)
    assert_receive {:fixture_request, request}
    refute Map.has_key?(request, :model)
    assert request.env_mode == :replace
    assert request.env == %{"PATH" => "/opt/bin", "OPENAI_API_KEY" => "fixture-key"}
    assert request.turn_runtime_timeout_ms > 0
    assert request.approval_timeout_ms <= 300_000
    assert_receive {:fixture_prompt, "Inspect the retained workspace"}
    assert {:ok, [%{sequence: 1}, %{sequence: 2}], handle} = Harness.poll(handle)
    assert handle.cursor == 2
    assert {:ok, [], ^handle} = Harness.poll(handle)
    assert :ok = Harness.cancel(handle)
    assert :ok = Harness.close(handle)
  end

  test "provider continuation uses the persisted provider history identity on the next turn" do
    directory = Path.join(System.tmp_dir!(), "hw-provider-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    command =
      Path.expand("../../priv/workspace_protocol/v1/fixtures/start.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()

    path = Path.join(directory, "provider-session")

    config = [
      cwd: "/workspace",
      acp_path: "/opt/bin/codex-acp",
      env: %{"OPENAI_API_KEY" => "fixture-key"},
      session_api: FixtureSession,
      process_api: FixtureSession,
      provider_session_file: path
    ]

    {:ok, handle} = Harness.start(command, config)
    assert_receive {:fixture_request, first}
    refute Map.has_key?(first, :provider_session_id)
    assert :ok = Harness.close(handle)
    assert File.read!(path) == "provider_history_fixture"
    {:ok, next} = Harness.start(command, config)
    assert_receive {:fixture_request, second}
    assert second.provider_session_id == "provider_history_fixture"
    assert :ok = Harness.close(next)
  end
end
