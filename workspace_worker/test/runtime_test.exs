defmodule Hermitscale.WorkspaceWorker.RuntimeTest do
  use ExUnit.Case, async: true

  alias Hermitscale.WorkspaceWorker.{FixtureAdapter, Journal, Runtime}

  test "terminal Harness observation exports durable evidence after verified writer termination" do
    directory = Path.join(System.tmp_dir!(), "hw-runtime-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(directory) end)

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
         config: [receiver: self(), terminal: true]}
      )

    command =
      Path.expand("../../priv/workspace_protocol/v1/fixtures/start.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()

    assert {:ok, %{"status" => "accepted"}} = Runtime.execute(runtime, command)
    assert_receive {:fixture_started, "operation_fixture"}
    assert_receive :fixture_polled, 1_000
    assert_receive :fixture_closed
    _ = :sys.get_state(runtime)

    assert {:ok,
            %{
              "status" => "completed",
              "observed_outcome" => "completed",
              "termination_confirmed" => true
            }} = Journal.status(journal, "operation_fixture")

    assert {:ok, %{"status" => "completed"}} = Runtime.execute(runtime, command)
    refute_receive {:fixture_started, _operation}
  end
end
