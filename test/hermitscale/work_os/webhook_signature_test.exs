defmodule Hermitscale.WorkOS.WebhookSignatureTest do
  use ExUnit.Case, async: true

  alias Hermitscale.WorkOS.WebhookSignature

  test "verifies exact raw bytes, timestamp tolerance, and overlapping secrets" do
    body = ~s({"id":"event_123","value":"exact bytes"})
    timestamp = 1_721_999_900
    old_secret = "whsec_old"
    current_secret = "whsec_current"

    signature =
      :crypto.mac(:hmac, :sha256, current_secret, "#{timestamp}.#{body}")
      |> Base.encode16(case: :lower)

    header = "t=#{timestamp}, v1=bad, v1=#{signature}"

    assert :ok =
             WebhookSignature.verify(body, header, [old_secret, current_secret],
               now: timestamp + 60,
               tolerance_seconds: 300
             )

    assert {:error, :invalid_signature} =
             WebhookSignature.verify(body <> " ", header, [old_secret, current_secret],
               now: timestamp + 60
             )

    assert {:error, :stale_signature} =
             WebhookSignature.verify(body, header, [current_secret],
               now: timestamp + 301,
               tolerance_seconds: 300
             )
  end

  test "accepts millisecond timestamps while signing their original representation" do
    body = "{}"
    timestamp_ms = 1_721_999_900_000

    signature =
      :crypto.mac(:hmac, :sha256, "secret", "#{timestamp_ms}.#{body}")
      |> Base.encode16(case: :lower)

    assert :ok =
             WebhookSignature.verify(body, "t=#{timestamp_ms},v1=#{signature}", ["secret"],
               now: 1_721_999_900
             )
  end
end
