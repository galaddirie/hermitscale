defmodule HermitscaleWeb.SessionHandoffs do
  @moduledoc "Single-use browser cookie refresh handoffs; identity authority stays with the provider."
  use GenServer

  @ttl_ms 60_000
  @maximum_entries 1_024

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Retains the rotated seal for at most one minute, bound to the incoming browser cookie."
  def create(incoming_seal, refreshed_seal, server \\ __MODULE__, return_to \\ "/agents")
      when is_binary(incoming_seal) and is_binary(refreshed_seal) do
    if valid_return_to?(return_to) do
      GenServer.call(
        server,
        {:create, :crypto.hash(:sha256, incoming_seal), refreshed_seal, return_to}
      )
    else
      {:error, :invalid_return_to}
    end
  end

  @doc "Consumes a handoff once. Expired, mismatched, and reused nonces grant no authority."
  def consume(nonce, incoming_seal, server \\ __MODULE__)

  def consume(nonce, incoming_seal, server)
      when is_binary(nonce) and byte_size(nonce) == 43 and is_binary(incoming_seal) do
    GenServer.call(server, {:consume, nonce, :crypto.hash(:sha256, incoming_seal)})
  end

  def consume(_nonce, _incoming_seal, _server), do: {:error, :invalid_handoff}

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    {:ok, %{entries: %{}, clock: clock}}
  end

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, "[REDACTED]") |> Map.put(:message, "[REDACTED]")

  @impl true
  def handle_call({:create, binding, seal, return_to}, _from, state) do
    now = state.clock.()
    entries = Map.reject(state.entries, fn {_nonce, entry} -> entry.expires_at <= now end)

    if map_size(entries) < @maximum_entries do
      nonce = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      entry = %{
        binding: binding,
        sealed_session: seal,
        return_to: return_to,
        expires_at: now + @ttl_ms
      }

      Process.send_after(self(), {:expire, nonce}, @ttl_ms)
      {:reply, {:ok, nonce}, %{state | entries: Map.put(entries, nonce, entry)}}
    else
      {:reply, {:error, :handoff_capacity}, %{state | entries: entries}}
    end
  end

  def handle_call({:consume, nonce, binding}, _from, state) do
    {entry, entries} = Map.pop(state.entries, nonce)

    result =
      case entry do
        %{binding: expected, sealed_session: seal, return_to: return_to, expires_at: expires_at} ->
          if expires_at > state.clock.() and Plug.Crypto.secure_compare(binding, expected),
            do: {:ok, %{sealed_session: seal, return_to: return_to}},
            else: {:error, :invalid_handoff}

        nil ->
          {:error, :invalid_handoff}
      end

    {:reply, result, %{state | entries: entries}}
  end

  @impl true
  def handle_info({:expire, nonce}, state),
    do: {:noreply, %{state | entries: Map.delete(state.entries, nonce)}}

  defp valid_return_to?(path) when is_binary(path) do
    case String.split(path, "/", trim: false) do
      ["", root] when root in ~w(agents apps workflows) ->
        true

      ["", root, id] when root in ~w(agents apps) ->
        match?({:ok, _uuid}, Ecto.UUID.cast(id))

      ["", "apps", id, "build"] ->
        match?({:ok, _uuid}, Ecto.UUID.cast(id))

      ["", "workflows", id] ->
        Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_:-]{0,127}\z/, id)

      _other ->
        false
    end
  end

  defp valid_return_to?(_path), do: false
end
