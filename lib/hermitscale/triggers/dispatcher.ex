defmodule Hermitscale.Triggers.Dispatcher do
  @moduledoc """
  The single choke point between a trigger firing and a workflow run.

  Every trigger mode — manual, webhook, schedule, polling, stream — dispatches
  through `fire/3`, which applies, in order:

    1. Idempotency: a firing row keyed by `{trigger_id, idempotency_key}`;
       a duplicate key means the event was already handled and dedupes.
    2. Admission: the trigger's `max_concurrent_runs` config, if set, bounds
       concurrently running runs for the graph (over-limit firings are
       recorded as `:rejected`).
    3. Envelope: a uniform provenance wrapper every run input carries.
    4. Dispatch: `Workflows.start_run/3` on the trigger's graph.
  """

  import Ecto.Query

  alias Hermitscale.Repo
  alias Hermitscale.Triggers.{Firing, Trigger}
  alias Hermitscale.Workflows
  alias Hermitscale.Workflows.Run

  @type result ::
          {:ok, Run.t()}
          | {:ok, :deduped}
          | {:error, :disabled}
          | {:error, :rejected}
          | {:error, {:start_run, term()}}

  @doc """
  Fires a trigger with a payload.

  Options:

    * `:idempotency_key` — stable identity of the source event (webhook
      delivery id, poll event key, schedule occurrence). Defaults to a fresh
      UUID, i.e. no deduplication.
    * `:run_opts` — options forwarded to `Workflows.start_run/3`.
  """
  @spec fire(Trigger.t() | struct(), map(), keyword()) :: result()
  def fire(%Trigger{} = trigger, payload, opts \\ []) do
    trigger = Repo.preload(trigger, :graph)

    with :ok <- ensure_enabled(trigger),
         {:ok, firing} <- insert_firing(trigger, opts) do
      case admit(trigger) do
        :ok ->
          dispatch(trigger, firing, payload, opts)

        {:error, :max_concurrent_runs} ->
          conclude(firing, %{outcome: :rejected, error: %{"reason" => "max_concurrent_runs"}})
          {:error, :rejected}
      end
    else
      {:error, :duplicate} -> {:ok, :deduped}
      {:error, :disabled} -> {:error, :disabled}
    end
  end

  defp ensure_enabled(%Trigger{status: :enabled}), do: :ok
  defp ensure_enabled(%Trigger{}), do: {:error, :disabled}

  defp insert_firing(trigger, opts) do
    now = DateTime.utc_now(:second)

    attrs = %{
      trigger_id: trigger.id,
      idempotency_key: Keyword.get(opts, :idempotency_key) || Ecto.UUID.generate(),
      outcome: :dispatched,
      fired_at: now
    }

    %Firing{}
    |> Firing.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, firing} ->
        {:ok, firing}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :trigger_id) do
          claim_failed_firing(trigger.id, attrs.idempotency_key, now)
        else
          raise ArgumentError, "firing insert failed for reasons other than idempotency"
        end
    end
  end

  # A key that already dispatched (or was deliberately rejected) is a true
  # duplicate. A key whose previous attempt failed to start a run is a retry:
  # claim it atomically so exactly one concurrent retrier proceeds.
  defp claim_failed_firing(trigger_id, key, now) do
    query =
      Firing
      |> where([firing], firing.trigger_id == ^trigger_id)
      |> where([firing], firing.idempotency_key == ^key and firing.outcome == :failed)

    case Repo.update_all(query, set: [outcome: :dispatched, error: nil, fired_at: now]) do
      {1, _returning} -> {:ok, Repo.get_by!(Firing, trigger_id: trigger_id, idempotency_key: key)}
      {0, _returning} -> {:error, :duplicate}
    end
  end

  defp admit(%Trigger{config: config, workflow_graph_id: graph_id}) do
    case config["max_concurrent_runs"] do
      limit when is_integer(limit) and limit > 0 ->
        running =
          Run
          |> where([run], run.workflow_graph_id == ^graph_id and run.status == :running)
          |> Repo.aggregate(:count)

        if running < limit, do: :ok, else: {:error, :max_concurrent_runs}

      _no_limit ->
        :ok
    end
  end

  defp dispatch(trigger, firing, payload, opts) do
    envelope = envelope(trigger, firing, payload)

    case Workflows.start_run(trigger.graph, envelope, run_opts(opts)) do
      {:ok, run} ->
        conclude(firing, %{run_id: run.id})
        {:ok, run}

      {:error, reason} ->
        conclude(firing, %{outcome: :failed, error: %{"reason" => inspect(reason)}})
        {:error, {:start_run, reason}}
    end
  end

  defp envelope(trigger, firing, payload) do
    %{
      "trigger" => %{
        "id" => trigger.id,
        "type" => trigger.type,
        "node_id" => trigger.node_id,
        "mode" => Atom.to_string(trigger.mode),
        "fired_at" => DateTime.to_iso8601(firing.fired_at)
      },
      "data" => payload
    }
  end

  defp run_opts(opts) do
    case Keyword.fetch(opts, :run_opts) do
      {:ok, run_opts} ->
        run_opts

      :error ->
        :hermitscale
        |> Application.get_env(Hermitscale.Triggers, [])
        |> Keyword.get(:run_opts, [])
    end
  end

  defp conclude(firing, attrs) do
    firing
    |> Firing.changeset(attrs)
    |> Repo.update!()
  end
end
