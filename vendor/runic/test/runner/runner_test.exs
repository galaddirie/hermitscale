defmodule Runic.Runner.RunnerTest do
  use ExUnit.Case, async: true

  require Runic

  describe "supervision tree" do
    test "starts with a name" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      pid = start_supervised!({Runic.Runner, name: runner_name})
      assert Process.alive?(pid)
    end

    test "starts all children" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})

      assert Process.whereis(Module.concat(runner_name, Store)) |> Process.alive?()
      assert Process.whereis(Module.concat(runner_name, Registry)) |> Process.alive?()
      assert Process.whereis(Module.concat(runner_name, TaskSupervisor)) |> Process.alive?()
      assert Process.whereis(Module.concat(runner_name, WorkerSupervisor)) |> Process.alive?()
    end

    test "raises without :name" do
      assert_raise KeyError, fn ->
        Runic.Runner.start_link([])
      end
    end

    test "ETS table exists after startup" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      table_name = Module.concat(runner_name, StoreTable)
      assert :ets.info(table_name) != :undefined
    end
  end

  describe "naming" do
    test "multiple runners with different names don't conflict" do
      runner1 = :"test_runner_#{System.unique_integer([:positive])}"
      runner2 = :"test_runner_#{System.unique_integer([:positive])}"

      pid1 = start_supervised!({Runic.Runner, name: runner1}, id: :runner1)
      pid2 = start_supervised!({Runic.Runner, name: runner2}, id: :runner2)

      assert pid1 != pid2
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
    end
  end

  describe "store access" do
    test "get_store returns the store module and state" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})

      {store_mod, store_state} = Runic.Runner.get_store(runner_name)
      assert store_mod == Runic.Runner.Store.ETS
      assert is_map(store_state)
      assert Map.has_key?(store_state, :table)
    end
  end

  describe "API shell" do
    test "lookup returns nil for non-existent workflow" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      assert Runic.Runner.lookup(runner_name, :nonexistent) == nil
    end

    test "list_workflows returns empty list initially" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      assert Runic.Runner.list_workflows(runner_name) == []
    end

    test "run returns {:error, :not_found} for non-existent workflow" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      assert Runic.Runner.run(runner_name, :nonexistent, :input) == {:error, :not_found}
    end

    test "get_results returns {:error, :not_found} for non-existent workflow" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      assert Runic.Runner.get_results(runner_name, :nonexistent) == {:error, :not_found}
    end

    test "get_workflow returns {:error, :not_found} for non-existent workflow" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      assert Runic.Runner.get_workflow(runner_name, :nonexistent) == {:error, :not_found}
    end

    test "stop returns {:error, :not_found} for non-existent workflow" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      assert Runic.Runner.stop(runner_name, :nonexistent) == {:error, :not_found}
    end

    test "resume returns {:error, :not_found} when no persisted state" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      assert Runic.Runner.resume(runner_name, :nonexistent) == {:error, :not_found}
    end
  end

  describe "custom options" do
    test "accepts custom store options" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"

      start_supervised!({Runic.Runner.Store.ETS, runner_name: runner_name})

      start_supervised!(
        {Runic.Runner, name: runner_name, store: Runic.Runner.Store.ETS, store_opts: []}
      )

      assert Process.whereis(Module.concat(runner_name, Store)) |> Process.alive?()
    end

    test "explicit stores are externally supervised" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runic.Runner,
         name: runner_name,
         store: Runic.TestSupport.StatelessStore,
         store_opts: [repo: :external_repo]}
      )

      refute Process.whereis(Module.concat(runner_name, Store))
      assert Process.whereis(Module.concat(runner_name, Registry)) |> Process.alive?()

      {store_mod, store_state} = Runic.Runner.get_store(runner_name)
      assert store_mod == Runic.TestSupport.StatelessStore
      assert store_state.runner_name == runner_name
      assert store_state.repo == :external_repo

      workflow =
        Runic.workflow(
          name: :identity,
          steps: [Runic.step(fn input -> input end, name: :echo)]
        )

      {:ok, _pid} = Runic.Runner.start_workflow(runner_name, :workflow_1, workflow)
      :ok = Runic.Runner.run(runner_name, :workflow_1, :hello)
      assert_workflow_idle(runner_name, :workflow_1)

      assert {:ok, %{echo: :hello}} =
               Runic.Runner.get_results(runner_name, :workflow_1, components: [:echo])
    end

    test "explicit ETS store must be started separately" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"

      start_supervised!({Runic.Runner.Store.ETS, runner_name: runner_name})
      start_supervised!({Runic.Runner, name: runner_name, store: Runic.Runner.Store.ETS})

      assert Process.whereis(Module.concat(runner_name, Store)) |> Process.alive?()

      {store_mod, store_state} = Runic.Runner.get_store(runner_name)
      assert store_mod == Runic.Runner.Store.ETS
      assert store_state.runner_name == runner_name
    end
  end

  defp assert_workflow_idle(runner, workflow_id, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_until_idle(runner, workflow_id, deadline)
  end

  defp wait_until_idle(runner, workflow_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("Workflow #{inspect(workflow_id)} did not reach idle within timeout")
    end

    case Runic.Runner.lookup(runner, workflow_id) do
      nil ->
        flunk("Workflow #{inspect(workflow_id)} not found")

      pid ->
        state = :sys.get_state(pid)

        if state.status == :idle and map_size(state.active_tasks) == 0 do
          :ok
        else
          Process.sleep(10)
          wait_until_idle(runner, workflow_id, deadline)
        end
    end
  end
end
