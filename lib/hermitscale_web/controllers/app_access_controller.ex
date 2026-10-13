defmodule HermitscaleWeb.AppAccessController do
  use HermitscaleWeb, :controller

  def open(conn, %{"id" => app_id}) do
    case HermitscaleWeb.AppGateway.open_url(conn.assigns.current_scope, app_id) do
      {:ok, url} ->
        redirect(conn, external: url)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Private app access is unavailable.")
        |> redirect(to: ~p"/apps/#{app_id}/build")
    end
  end
end
