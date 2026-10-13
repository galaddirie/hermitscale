defmodule HermitscaleWeb.AppAccessController do
  use HermitscaleWeb, :controller
  alias Hermitscale.Apps

  def open(conn, %{"id" => app_id, "preview_id" => preview_id}) do
    case Apps.create_access_grant(conn.assigns.current_scope, app_id, %{preview_id: preview_id}) do
      {:ok, %{url: url}} ->
        redirect(conn, external: url)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Preview is unavailable. Load a verified preview from Build.")
        |> redirect(to: ~p"/apps/#{app_id}/build")
    end
  end

  def open_environment(conn, %{"id" => app_id, "environment_id" => environment_id}) do
    case Apps.create_access_grant(conn.assigns.current_scope, app_id, %{
           environment_id: environment_id
         }) do
      {:ok, %{url: url}} ->
        redirect(conn, external: url)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Published app is unavailable.")
        |> redirect(to: ~p"/apps/#{app_id}")
    end
  end
end
