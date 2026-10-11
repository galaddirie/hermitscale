defmodule HermitscaleWeb.WorkOSWebhookController do
  use HermitscaleWeb, :controller

  alias Hermitscale.WorkOS.EventInbox
  alias HermitscaleWeb.CacheBodyReader

  def create(conn, %{"endpoint_token" => endpoint_token}) do
    signature = get_req_header(conn, "workos-signature") |> List.first()
    raw_body = CacheBodyReader.raw_body(conn)

    case EventInbox.receive_webhook(endpoint_token, signature, raw_body) do
      {:ok, _event} ->
        conn
        |> put_status(:ok)
        |> json(%{received: true})

      {:error, reason} when reason in [:invalid_endpoint_token, :invalid_signature] ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid webhook authentication"})

      {:error, :stale_signature} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "stale webhook signature"})

      {:error, _reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid webhook"})
    end
  end
end
