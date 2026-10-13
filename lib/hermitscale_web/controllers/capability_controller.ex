defmodule HermitscaleWeb.CapabilityController do
  use HermitscaleWeb, :controller

  def create(conn, params) do
    case Hermitscale.Integrations.ExecutionAccess.issue_product(
           conn.assigns.current_scope,
           Map.get(params, "resource_ids", []),
           Map.get(params, "actions", []),
           max_calls: Map.get(params, "max_calls", 50),
           ttl_seconds: Map.get(params, "ttl_seconds", 3600)
         ) do
      {:ok, issued} -> json(conn, %{token: issued.token, expires_at: issued.record.expires_at})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end
end
