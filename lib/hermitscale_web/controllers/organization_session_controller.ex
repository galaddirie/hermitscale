defmodule HermitscaleWeb.OrganizationSessionController do
  use HermitscaleWeb, :controller

  alias Hermitscale.WorkOS.Session
  alias HermitscaleWeb.UserAuth

  def update(conn, %{"id" => organization_id}) do
    with handle when is_binary(handle) <- UserAuth.session_handle(conn),
         {:ok, _scope} <-
           Session.switch_organization(
             handle,
             conn.assigns.current_scope,
             organization_id,
             UserAuth.request_metadata(conn)
           ) do
      conn
      |> put_flash(:info, "Active organization changed.")
      |> redirect(to: ~p"/users/settings")
    else
      {:error, :unavailable} ->
        conn
        |> put_flash(
          :error,
          "WorkOS is temporarily unavailable, so the organization was not changed."
        )
        |> redirect(to: ~p"/users/settings")

      _other ->
        conn
        |> put_flash(:error, "You cannot switch to that organization.")
        |> redirect(to: ~p"/users/settings")
    end
  end
end
