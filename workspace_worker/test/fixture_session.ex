defmodule Hermitscale.WorkspaceWorker.FixtureSession do
  @moduledoc false

  def start(:codex, request) do
    send(self(), {:fixture_request, request})
    {:ok, "harness_session_fixture"}
  end

  def info("harness_session_fixture") do
    if Process.delete(:fixture_initializing) == true,
      do: {:ok, %{state: :starting}},
      else: {:ok, %{state: :idle, provider_session_id: "provider_history_fixture"}}
  end

  def send_message("harness_session_fixture", prompt) do
    send(self(), {:fixture_prompt, prompt})
    {:ok, "harness_turn_fixture"}
  end

  def replay("harness_session_fixture", cursor: cursor, limit: 100) do
    events = [
      %{sequence: 1, type: :output_text_delta, payload: %{"text" => "Fixture output"}},
      %{sequence: 2, type: :turn_completed, payload: %{}}
    ]

    {:ok, Enum.filter(events, &(&1.sequence > cursor))}
  end

  def interrupt("harness_session_fixture", "harness_turn_fixture"), do: :ok
  def close("harness_session_fixture"), do: :ok
  def list(_options), do: []
end
