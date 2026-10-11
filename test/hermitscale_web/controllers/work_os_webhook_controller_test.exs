defmodule HermitscaleWeb.WorkOSWebhookControllerTest do
  use HermitscaleWeb.ConnCase, async: false

  alias Hermitscale.Repo
  alias Hermitscale.WorkOS.Event

  test "authenticates the exact JSON request body outside the browser pipeline", %{conn: conn} do
    raw_body =
      Jason.encode!(%{
        "id" => "event_controller_123",
        "event" => "session.revoked",
        "created_at" => "2026-07-26T18:00:00.000000Z",
        "data" => %{"id" => "session_123"}
      })

    timestamp = System.system_time(:second)
    signature = signature(timestamp, raw_body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("workos-signature", "t=#{timestamp},v1=#{signature}")
      |> post("/webhooks/workos/workos-test-endpoint", raw_body)

    assert json_response(conn, 200) == %{"received" => true}
    assert Repo.get!(Event, "event_controller_123").status == :pending
  end

  test "rejects a signature for different raw bytes", %{conn: conn} do
    raw_body =
      Jason.encode!(%{
        "id" => "event_controller_bad",
        "event" => "session.revoked",
        "created_at" => "2026-07-26T18:00:00.000000Z",
        "data" => %{"id" => "session_123"}
      })

    timestamp = System.system_time(:second)
    signature = signature(timestamp, raw_body <> " ")

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("workos-signature", "t=#{timestamp},v1=#{signature}")
      |> post("/webhooks/workos/workos-test-endpoint", raw_body)

    assert json_response(conn, 401) == %{"error" => "invalid webhook authentication"}
    assert Repo.get(Event, "event_controller_bad") == nil
  end

  defp signature(timestamp, body) do
    :crypto.mac(
      :hmac,
      :sha256,
      "whsec_test_hermitscale",
      "#{timestamp}.#{body}"
    )
    |> Base.encode16(case: :lower)
  end
end
