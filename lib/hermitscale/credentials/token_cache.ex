defmodule Hermitscale.Credentials.TokenCache do
  @moduledoc """
  Expiry-aware ETS cache for resolved OAuth access tokens.

  Keeps the hot resolve path off backend APIs: entries carry an absolute
  staleness deadline chosen by the caller (token expiry minus refresh margin,
  or a short TTL for managed backends). Reads and writes go straight to the
  public ETS table; the GenServer only owns the table and sweeps expired
  entries so revoked credentials don't linger as dead weight.
  """

  use GenServer

  @sweep_interval :timer.minutes(1)

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @doc "Returns `{:ok, token}` while the entry is fresh, `:miss` otherwise."
  def get(credential_id, table \\ __MODULE__) do
    now = System.system_time(:millisecond)

    case :ets.lookup(table, credential_id) do
      [{_id, token, stale_at}] when stale_at > now -> {:ok, token}
      _other -> :miss
    end
  end

  @doc "Caches a token until `stale_at`, after which `get/2` misses."
  def put(credential_id, token, %DateTime{} = stale_at, table \\ __MODULE__) do
    :ets.insert(table, {credential_id, token, DateTime.to_unix(stale_at, :millisecond)})
    :ok
  end

  @doc "Drops a credential's cached token (rotation, revocation, refresh failure)."
  def invalidate(credential_id, table \\ __MODULE__) do
    :ets.delete(table, credential_id)
    :ok
  end

  # --- Callbacks ---

  @impl true
  def init(name) do
    table = :ets.new(name, [:named_table, :set, :public, read_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(state.table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
