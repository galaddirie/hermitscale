defmodule Hermitscale.Workflows.PostgresStore do
  @moduledoc """
  Postgres-backed `Runic.Runner.Store`.

  This is the simple durable baseline: workflow event bytes and queryable run
  metadata live in Postgres. A local SQLite/Litestream hot log can be added later
  if checkpoint write volume warrants it.
  """

  @behaviour Runic.Runner.Store

  import Ecto.Query

  alias Hermitscale.Workflows.{Run, RunEvent}

  @impl true
  def init_store(opts) do
    {:ok, %{repo: Keyword.fetch!(opts, :repo)}}
  end

  @impl true
  def save(workflow_id, log, %{repo: repo}) do
    id = normalize_id(workflow_id)

    repo.transaction(fn ->
      run = lock_or_create_run!(repo, id)
      {_count, _rows} = repo.delete_all(from event in RunEvent, where: event.run_id == ^id)

      insert_events!(repo, id, 1, log)

      run
      |> Run.changeset(%{last_event_sequence: length(log)})
      |> repo.update!()
    end)
    |> transaction_result()
  end

  @impl true
  def load(workflow_id, %{repo: repo}) do
    id = normalize_id(workflow_id)

    events =
      RunEvent
      |> where([event], event.run_id == ^id)
      |> order_by([event], asc: event.sequence)
      |> select([event], event.event)
      |> repo.all()

    case {events, repo.exists?(from run in Run, where: run.id == ^id)} do
      {[], false} -> {:error, :not_found}
      {events, _exists?} -> {:ok, Enum.map(events, &:erlang.binary_to_term/1)}
    end
  end

  @impl true
  def checkpoint(workflow_id, log, state), do: save(workflow_id, log, state)

  @impl true
  def append(workflow_id, events, %{repo: repo}) when is_list(events) do
    id = normalize_id(workflow_id)

    repo.transaction(fn ->
      run = lock_or_create_run!(repo, id)
      start_sequence = run.last_event_sequence + 1
      insert_events!(repo, id, start_sequence, events)
      cursor = run.last_event_sequence + length(events)

      run
      |> Run.changeset(%{last_event_sequence: cursor})
      |> repo.update!()

      cursor
    end)
  end

  @impl true
  def stream(workflow_id, state) do
    case load(workflow_id, state) do
      {:ok, events} -> {:ok, events}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @impl true
  def delete(workflow_id, %{repo: repo}) do
    id = normalize_id(workflow_id)

    case repo.get(Run, id) do
      nil -> :ok
      run -> repo.delete(run) |> transaction_result()
    end
  end

  @impl true
  def list(%{repo: repo}) do
    ids =
      Run
      |> order_by([run], asc: run.inserted_at)
      |> select([run], run.id)
      |> repo.all()

    {:ok, ids}
  end

  @impl true
  def exists?(workflow_id, %{repo: repo}) do
    id = normalize_id(workflow_id)
    repo.exists?(from run in Run, where: run.id == ^id)
  end

  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(id), do: to_string(id)

  defp lock_or_create_run!(repo, id) do
    query = from run in Run, where: run.id == ^id, lock: "FOR UPDATE"

    case repo.one(query) do
      %Run{} = run ->
        run

      nil ->
        %Run{}
        |> Run.changeset(%{id: id, status: :running, last_event_sequence: 0})
        |> repo.insert!()
    end
  end

  defp insert_events!(_repo, _run_id, _start_sequence, []), do: :ok

  defp insert_events!(repo, run_id, start_sequence, events) do
    now = DateTime.utc_now(:second)

    entries =
      events
      |> Enum.with_index(start_sequence)
      |> Enum.map(fn {event, sequence} ->
        %{
          run_id: run_id,
          sequence: sequence,
          event: :erlang.term_to_binary(event),
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, _rows} = repo.insert_all(RunEvent, entries)
    :ok
  end

  defp transaction_result({:ok, _value}), do: :ok
  defp transaction_result({:error, _reason} = error), do: error
end
