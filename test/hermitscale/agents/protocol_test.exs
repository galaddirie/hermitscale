defmodule Hermitscale.Agents.ProtocolTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Agents.Protocol

  @fixtures Path.expand("../../../priv/workspace_protocol/v1/fixtures", __DIR__)

  test "host consumes the same versioned start and event fixtures as the worker" do
    command = fixture("start")
    event = fixture("event")
    assert {:ok, ^command} = Protocol.validate_command(command)
    assert {:ok, ^event} = Protocol.validate_event(event)
    assert command["payload_digest"] == Protocol.payload_digest(command["payload"])
  end

  test "rejects versions, unknown fields, payload tampering, non-UTC and expired deadlines" do
    command = fixture("start")

    assert {:error, :unsupported_version_or_identity} =
             Protocol.validate_command(%{command | "version" => 2})

    assert {:error, :invalid_keys} =
             Protocol.validate_command(Map.put(command, "fleet_token", "not-authorized"))

    assert {:error, :payload_digest_mismatch} =
             Protocol.validate_command(%{command | "payload" => %{"prompt" => "changed"}})

    assert {:error, :deadline_must_be_utc} =
             Protocol.validate_command(%{command | "deadline" => "2099-01-01T00:00:00+01:00"})

    assert {:error, :deadline_expired} =
             Protocol.validate_command(command, now: ~U[2100-01-01 00:00:00Z])

    assert {:error, :invalid_command} = Protocol.validate_command(%{command | "deadline" => nil})
  end

  test "canonical object digest is independent of insertion order and preserves array order" do
    assert Protocol.payload_digest(%{"a" => 1, "b" => 2}) ==
             Protocol.payload_digest(%{"b" => 2, "a" => 1})

    refute Protocol.payload_digest(%{"a" => [1, 2]}) == Protocol.payload_digest(%{"a" => [2, 1]})
  end

  test "bounds evidence and redacts structured and configured transient secrets" do
    assert %{"access_token" => "[REDACTED]", "text" => "hello [REDACTED]"} =
             Protocol.redact_payload(
               %{"access_token" => "sensitive", "text" => "hello transient"},
               ["transient"]
             )

    assert %{"input_tokens" => 12, "output_tokens" => 3} =
             Protocol.redact_payload(%{"input_tokens" => 12, "output_tokens" => 3})

    assert %{"truncated" => true} =
             Protocol.redact_payload(%{"text" => String.duplicate("x", 20_000)})

    assert {:error, :message_too_large} =
             Protocol.validate_event(%{
               fixture("event")
               | "payload" => %{"text" => String.duplicate("x", 20_000)}
             })
  end

  defp fixture(name),
    do: @fixtures |> Path.join(name <> ".json") |> File.read!() |> Jason.decode!()
end
