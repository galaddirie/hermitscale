defmodule Hermitscale.WorkspaceWorker.FixtureAdapter do
  @moduledoc false

  def start(command, config) do
    receiver = Keyword.fetch!(config, :receiver)
    send(receiver, {:fixture_started, command["operation_id"]})
    {:ok, %{receiver: receiver, terminal: Keyword.get(config, :terminal, false)}}
  end

  def poll(%{terminal: true} = handle) do
    send(handle.receiver, :fixture_polled)
    {:ok, [%{sequence: 1, type: :turn_completed, payload: %{}}], handle}
  end

  def poll(%{terminal: false} = handle), do: {:ok, [], handle}

  def cancel(handle),
    do: send(handle.receiver, :fixture_cancel_requested) |> then(fn _ -> :ok end)

  def close(handle) do
    send(handle.receiver, :fixture_closed)
    :ok
  end

  def verify_termination(_handle), do: {:ok, %{groups: []}}
  def cleanup_failed_start(_config), do: {:ok, %{groups: []}}
  def recover_termination(_config), do: {:error, :termination_evidence_missing}
  def acquire(_deadline, _config), do: :ok
  def release(_config), do: :ok
end
