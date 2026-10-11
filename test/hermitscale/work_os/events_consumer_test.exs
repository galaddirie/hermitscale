defmodule Hermitscale.WorkOS.EventsConsumerTest do
  use Hermitscale.DataCase, async: false

  alias Hermitscale.Repo
  alias Hermitscale.WorkOS.{Event, EventCursor, EventsConsumer}
  alias Hermitscale.WorkOSTest.Client

  setup do
    start_supervised!({Client, %{}})
    previous = Application.get_env(:hermitscale, EventsConsumer, [])
    Application.put_env(:hermitscale, EventsConsumer, Keyword.put(previous, :client, Client))

    on_exit(fn -> Application.put_env(:hermitscale, EventsConsumer, previous) end)
  end

  test "an empty Events API page preserves a bounded range cursor" do
    range_start = ~U[2026-07-26 14:55:00.000000Z]
    assert {:ok, _cursor} = EventsConsumer.reset_from(range_start)

    assert {:ok, :caught_up} = EventsConsumer.drain_page()

    cursor = Repo.get!(EventCursor, "primary")
    assert cursor.after_cursor == nil
    assert cursor.range_start == range_start

    assert [{:list_events, [nil, event_types, [range_start: ^range_start]]}] = Client.calls()
    assert "session.revoked" in event_types
  end

  test "applies a nonempty page in order and advances to the last event ID" do
    first = event_envelope("event_1", "session.revoked", %{"id" => "session_1"})
    second = event_envelope("event_2", "session.revoked", %{"id" => "session_2"})

    Client.put_response(
      :list_events,
      {:ok, %{"data" => [first, second], "list_metadata" => %{"after" => nil}}}
    )

    assert {:ok, :more} = EventsConsumer.drain_page()

    cursor = Repo.get!(EventCursor, "primary")
    assert cursor.after_cursor == "event_2"
    assert cursor.range_start == nil
    assert Repo.get!(Event, "event_1").status == :processed
    assert Repo.get!(Event, "event_2").status == :processed
  end

  test "a supported projection failure blocks cursor advancement" do
    invalid = event_envelope("event_invalid", "user.updated", %{})

    Client.put_response(
      :list_events,
      {:ok,
       %{
         "data" => [invalid],
         "list_metadata" => %{"after" => "event_invalid"}
       }}
    )

    assert {:error, {:invalid_workos_object, "id"}} = EventsConsumer.drain_page()

    cursor = Repo.get!(EventCursor, "primary")
    assert cursor.after_cursor == nil
    assert Repo.get!(Event, "event_invalid").status == :failed
  end

  defp event_envelope(id, type, data) do
    %{
      "id" => id,
      "event" => type,
      "created_at" => "2026-07-26T15:00:00.000000Z",
      "data" => data
    }
  end
end
