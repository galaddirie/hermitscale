defmodule Hermitscale.WorkspaceWorker.JournalTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Hermitscale.WorkspaceWorker.Journal
  alias Hermitscale.WorkspaceProtocol.V1, as: Protocol

  setup do
    directory =
      Path.join(System.tmp_dir!(), "hermitscale-worker-#{System.unique_integer([:positive])}")

    path = Path.join(directory, "journal.jsonl")
    on_exit(fn -> File.rm_rf!(directory) end)
    options = [path: path, workspace_id: "workspace_fixture", secrets: ["transient-test-secret"]]
    journal = start_supervised!({Journal, options})
    %{journal: journal, options: options, path: path}
  end

  test "shared start fixture has one durable acceptance and rejects changed identity or payload",
       %{journal: journal} do
    fixture = Path.expand("../../priv/workspace_protocol/v1/fixtures/start.json", __DIR__)
    start = fixture |> File.read!() |> JSON.decode!()
    assert {:ok, %{"status" => "accepted", "cursor" => 1}} = Journal.execute(journal, start)
    assert {:ok, %{"status" => "accepted", "cursor" => 1}} = Journal.execute(journal, start)
    changed = %{start | "payload" => %{"prompt" => "Different work"}}
    changed = %{changed | "payload_digest" => Protocol.payload_digest(changed["payload"])}
    assert {:error, :command_conflict} = Journal.execute(journal, changed)

    assert {:error, :command_conflict} =
             Journal.execute(journal, %{start | "operation_id" => "other"})

    assert {:error, :workspace_mismatch} =
             Journal.execute(journal, %{start | "workspace_id" => "other"})
  end

  test "restart preserves epoch and cursor identity and never admits the accepted effect again",
       context do
    start = command("start", "first", %{"prompt" => "Inspect workspace"})
    assert {:ok, accepted} = Journal.execute(context.journal, start)
    :ok = Journal.mark_running(context.journal, "operation_fixture")
    :ok = stop_supervised(Journal)
    journal = start_supervised!({Journal, context.options})
    assert {:ok, recovered} = Journal.execute(journal, start)
    assert recovered["status"] == "uncertain"
    assert recovered["epoch"] == accepted["epoch"]
    assert recovered["termination_confirmed"] == false

    assert {:error, :writer_active} =
             Journal.execute(
               journal,
               command("start", "second", %{"prompt" => "New work"}, "operation_second", 2)
             )

    read =
      command("read_events", "read", %{
        "epoch" => recovered["epoch"],
        "cursor" => 2,
        "limit" => 100
      })

    assert {:ok, %{"events" => [%{"type" => "recovered", "cursor" => 3}]}} =
             Journal.execute(journal, read)
  end

  test "cancellation and terminal events do not claim writer termination or advance generation",
       %{journal: journal} do
    assert {:ok, _} = Journal.execute(journal, command("start", "first", %{"prompt" => "Work"}))

    assert {:ok, %{"cancel_requested" => true, "termination_confirmed" => false}} =
             Journal.execute(journal, command("cancel", "cancel", %{}))

    next = command("start", "next", %{"prompt" => "Follow-up"}, "operation_second", 2)
    assert {:error, :writer_active} = Journal.execute(journal, next)
    assert :ok = Journal.terminal_observed(journal, "operation_fixture", "interrupted")
    assert {:error, :writer_active} = Journal.execute(journal, next)

    assert :ok =
             Journal.confirm_termination(journal, "operation_fixture", "interrupted", %{
               "test_evidence" => "fixture_writer_stopped"
             })

    assert {:ok, %{"status" => "accepted", "generation" => 2}} = Journal.execute(journal, next)

    assert {:error, :stale_generation} =
             Journal.execute(
               journal,
               command("start", "stale", %{"prompt" => "Stale"}, "operation_third", 1)
             )
  end

  test "events replay stably, gaps and future cursors are explicit", %{
    journal: journal
  } do
    assert {:ok, start} =
             Journal.execute(journal, command("start", "first", %{"prompt" => "Work"}))

    assert :ok =
             Journal.append_provider_event(journal, "operation_fixture", %{"text" => "Output"})

    read =
      command("read_events", "read", %{"epoch" => start["epoch"], "cursor" => 0, "limit" => 100})

    assert {:ok, page} = Journal.execute(journal, read)
    assert Enum.map(page["events"], & &1["cursor"]) == [1, 2]
    assert {:ok, ^page} = Journal.execute(journal, read)

    assert {:error, :history_gap} =
             Journal.execute(
               journal,
               command("read_events", "gap", %{
                 "epoch" => "missing",
                 "cursor" => 0,
                 "limit" => 100
               })
             )
  end

  test "redaction happens before durable event write and oversized evidence is marked", context do
    assert {:ok, _} =
             Journal.execute(context.journal, command("start", "first", %{"prompt" => "Work"}))

    assert :ok =
             Journal.append_provider_event(context.journal, "operation_fixture", %{
               "access_token" => "private",
               "text" => "transient-test-secret"
             })

    refute File.read!(context.path) =~ "transient-test-secret"
    refute File.read!(context.path) =~ "private"

    assert :ok =
             Journal.append_provider_event(context.journal, "operation_fixture", %{
               "text" => String.duplicate("x", 20_000)
             })

    assert File.read!(context.path) =~ "event_payload_limit"
  end

  test "torn unaccepted tail is removed while corrupt committed records prevent boot", context do
    assert {:ok, _} =
             Journal.execute(context.journal, command("start", "first", %{"prompt" => "Work"}))

    :ok = stop_supervised(Journal)
    File.write!(context.path, "{\"unfinished\":", [:append])
    journal = start_supervised!({Journal, context.options})
    assert {:ok, %{"status" => "uncertain"}} = Journal.status(journal, "operation_fixture")
    :ok = stop_supervised(Journal)
    File.write!(context.path, "invalid\n", [:append])

    assert {:error, {{:journal_unavailable, :corrupt_journal}, _child}} =
             start_supervised({Journal, context.options})
  end

  test "expired new work is rejected and accepted duplicates remain inspectable", %{
    journal: journal
  } do
    expired = %{
      command("start", "expired", %{"prompt" => "Work"})
      | "deadline" => "2000-01-01T00:00:00Z"
    }

    assert {:error, :deadline_expired} = Journal.execute(journal, expired)
    assert {:error, :operation_not_found} = Journal.status(journal, "operation_fixture")
  end

  test "storage failure refuses acceptance and does not leave a command to replay", context do
    :ok = stop_supervised(Journal)

    journal =
      start_supervised!(
        Supervisor.child_spec({Journal, Keyword.put(context.options, :max_bytes, 900)},
          restart: :temporary
        )
      )

    ref = Process.monitor(journal)

    log =
      capture_log(fn ->
        assert {:error, :journal_full} =
                 Journal.execute(journal, command("start", "first", %{"prompt" => "Work"}))

        assert_receive {:DOWN, ^ref, :process, ^journal, {:journal_unavailable, :journal_full}}
      end)

    refute log =~ "transient-test-secret"
    assert log =~ "[REDACTED]"
    recovered = start_supervised!({Journal, context.options})
    assert {:error, :operation_not_found} = Journal.status(recovered, "operation_fixture")
  end

  test "retained worker redacts each refreshed inference capability without a restart", context do
    :ok = stop_supervised(Journal)
    env_file = context.path <> ".env.json"
    File.write!(env_file, JSON.encode!(%{"OPENAI_API_KEY" => "first-turn-capability"}))

    journal =
      start_supervised!({Journal, Keyword.put(context.options, :provider_env_file, env_file)})

    {:ok, accepted} =
      Journal.execute(journal, command("start", "renew-start", %{"prompt" => "Work"}))

    :ok =
      Journal.append_provider_event(journal, "operation_fixture", %{
        "text" => "first-turn-capability"
      })

    File.write!(env_file, JSON.encode!(%{"OPENAI_API_KEY" => "second-turn-capability"}))

    :ok =
      Journal.append_provider_event(journal, "operation_fixture", %{
        "text" => "first-turn-capability second-turn-capability"
      })

    {:ok, page} =
      Journal.execute(
        journal,
        command("read_events", "renew-read", %{
          "epoch" => accepted["epoch"],
          "cursor" => 0,
          "limit" => 100
        })
      )

    output = JSON.encode!(page)
    refute output =~ "first-turn-capability"
    refute output =~ "second-turn-capability"
    refute File.read!(context.path) =~ "second-turn-capability"
    assert output =~ "REDACTED"
  end

  defp command(type, command_id, payload, operation_id \\ "operation_fixture", generation \\ 1) do
    %{
      "version" => 1,
      "workspace_id" => "workspace_fixture",
      "operation_id" => operation_id,
      "command_id" => command_id,
      "generation" => generation,
      "payload_digest" => Protocol.payload_digest(payload),
      "deadline" => "2099-01-01T00:00:00Z",
      "type" => type,
      "payload" => payload
    }
  end
end
