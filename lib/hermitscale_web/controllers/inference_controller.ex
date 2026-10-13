defmodule HermitscaleWeb.InferenceController do
  use HermitscaleWeb, :controller

  def create(conn, params) do
    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _missing -> nil
      end

    case Hermitscale.Integrations.InferenceGateway.request(token, params) do
      {:ok, response} ->
        content_type =
          case Req.Response.get_header(response, "content-type") do
            [value | _] -> value
            [] -> "application/json"
          end

        body = if is_binary(response.body), do: response.body, else: Jason.encode!(response.body)
        conn |> put_resp_content_type(content_type) |> send_resp(response.status, body)

      {:error, reason} ->
        conn
        |> put_status(
          if(reason in [:invalid_capability, :capability_expired, :capability_revoked],
            do: 401,
            else: 422
          )
        )
        |> json(%{error: %{message: "Inference request rejected", code: inspect(reason)}})
    end
  end
end
