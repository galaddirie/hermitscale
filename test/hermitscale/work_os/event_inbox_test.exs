defmodule Hermitscale.WorkOS.EventInboxTest do
  use Hermitscale.DataCase, async: false

  alias Hermitscale.Repo

  alias Hermitscale.WorkOS.{
    Event,
    EventInbox,
    EventRetentionWorker
  }

  test "deduplicates event envelopes by WorkOS event ID" do
    envelope = event_envelope("event_duplicate", "session.revoked", %{"id" => "session_123"})

    assert {:ok, %Event{event_id: "event_duplicate"}} = EventInbox.insert_envelope(envelope)
    assert {:ok, %Event{event_id: "event_duplicate"}} = EventInbox.insert_envelope(envelope)
    assert Repo.aggregate(Event, :count) == 1
  end

  test "classifies unsupported notifications as ignored without a domain mutation" do
    envelope = event_envelope("event_unknown", "future.resource.changed", %{"id" => "future_1"})

    assert {:ok, %Event{status: :ignored} = event} = EventInbox.insert_envelope(envelope)
    assert event.processing_error == "unsupported_event_type"
    assert event.processed_at
  end

  test "persists supported projection failures for diagnosis and retry" do
    envelope = event_envelope("event_bad_data", "user.updated", %{})
    assert {:ok, event} = EventInbox.insert_envelope(envelope)

    assert {:error, {:invalid_workos_object, "id"}} = EventInbox.process(event.event_id)

    failed = Repo.get!(Event, event.event_id)
    assert failed.status == :failed
    assert failed.processing_error =~ "invalid_workos_object"
    assert failed.payload == envelope
  end

  test "verifies a raw webhook, stores it, and wakes the ordered consumer" do
    envelope = event_envelope("event_signed", "session.revoked", %{"id" => "session_123"})
    raw_body = Jason.encode!(envelope)
    timestamp = System.system_time(:second)

    signature =
      :crypto.mac(
        :hmac,
        :sha256,
        "whsec_test_hermitscale",
        "#{timestamp}.#{raw_body}"
      )
      |> Base.encode16(case: :lower)

    assert {:ok, %Event{event_id: "event_signed"}} =
             EventInbox.receive_webhook(
               "workos-test-endpoint",
               "t=#{timestamp},v1=#{signature}",
               raw_body
             )

    assert Repo.aggregate(Oban.Job, :count) == 1

    assert {:error, :invalid_endpoint_token} =
             EventInbox.receive_webhook(
               "wrong-endpoint",
               "t=#{timestamp},v1=#{signature}",
               raw_body
             )
  end

  test "redacts old terminal payloads but preserves failed diagnostic payloads" do
    processed_envelope =
      event_envelope("event_processed", "session.revoked", %{"id" => "session_123"})

    failed_envelope = event_envelope("event_failed", "user.updated", %{})

    assert {:ok, processed} = EventInbox.insert_envelope(processed_envelope)
    assert {:ok, _processed} = EventInbox.process(processed.event_id)
    assert {:ok, failed} = EventInbox.insert_envelope(failed_envelope)
    assert {:error, _reason} = EventInbox.process(failed.event_id)

    cutoff = DateTime.add(DateTime.utc_now(:second), -48, :hour)

    from(event in Event, where: event.event_id in ^[processed.event_id, failed.event_id])
    |> Repo.update_all(set: [processed_at: cutoff])

    assert :ok = EventRetentionWorker.perform(%Oban.Job{})

    assert Repo.get!(Event, processed.event_id).payload == %{
             "event" => "session.revoked",
             "id" => "event_processed",
             "redacted" => true
           }

    assert Repo.get!(Event, failed.event_id).payload == failed_envelope
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
