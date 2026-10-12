defmodule Hermitscale.Triggers.Scheduler do
  @moduledoc """
  Turns due schedule-trigger rows into Oban jobs.

  Each tick selects enabled schedule triggers whose `next_fire_at` has passed
  — `FOR UPDATE SKIP LOCKED`, so concurrent ticks on other nodes skip rows
  this one is handling — enqueues a unique `FireWorker` job per row, and
  advances `next_fire_at` from the current time in the same transaction.

  Advancing from *now* rather than the missed occurrence means downtime fires
  at most one catch-up occurrence per trigger, then resumes the schedule.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Hermitscale.Repo
  alias Hermitscale.Triggers
  alias Hermitscale.Triggers.{FireWorker, Trigger}

  @tick_ms 20_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs one tick synchronously and returns the number of triggers fired. Used
  by tests; production relies on the timer.
  """
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @impl true
  def init(opts) do
    state = %{tick_ms: Keyword.get(opts, :tick_ms, @tick_ms)}
    schedule_tick(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    {:reply, run_tick(), state}
  end

  @impl true
  def handle_info(:tick, state) do
    case run_tick() do
      fired when is_integer(fired) -> :ok
      {:error, _reason} -> Logger.error("Trigger scheduler transaction failed")
    end

    schedule_tick(state)
    {:noreply, state}
  end

  defp run_tick do
    now = DateTime.utc_now(:second)

    result =
      Repo.transaction(fn ->
        due =
          Trigger
          |> where([trigger], trigger.mode == :schedule and trigger.status == :enabled)
          |> where([trigger], trigger.next_fire_at <= ^now)
          |> lock("FOR UPDATE SKIP LOCKED")
          |> Repo.all()

        Enum.each(due, fn trigger ->
          result =
            %{
              trigger_id: trigger.id,
              scheduled_for: DateTime.to_iso8601(trigger.next_fire_at)
            }
            |> FireWorker.new()
            |> Oban.insert()

          case result do
            {:ok, _job} -> :ok
            {:error, changeset} -> Repo.rollback({:enqueue, trigger.id, changeset})
          end

          Triggers.advance_next_fire_at(trigger, now)
        end)

        length(due)
      end)

    case result do
      {:ok, fired} -> fired
      {:error, _reason} = error -> error
    end
  end

  defp schedule_tick(state), do: Process.send_after(self(), :tick, state.tick_ms)
end
