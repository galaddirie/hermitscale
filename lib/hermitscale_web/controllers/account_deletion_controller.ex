defmodule HermitscaleWeb.AccountDeletionController do
  use HermitscaleWeb, :controller

  alias Hermitscale.Accounts
  alias Hermitscale.Accounts.AccountDeletionWorker
  alias Hermitscale.WorkOS.Session
  alias HermitscaleWeb.UserAuth

  @fresh_auth_minutes 10

  def delete(conn, _params) do
    case conn.assigns[:auth_session] do
      auth_session when not is_nil(auth_session) ->
        delete_with_fresh_session(conn, auth_session)

      _missing ->
        redirect_to_reauthentication(conn)
    end
  end

  defp delete_with_fresh_session(conn, auth_session) do
    if Session.fresh?(auth_session, @fresh_auth_minutes) do
      user = conn.assigns.current_scope.user

      with {:ok, _user} <- Accounts.request_account_deletion(conn.assigns.current_scope),
           {:ok, _revoked_count} <- Session.revoke_all_for_user(user),
           {:ok, _job} <-
             %{"user_id" => user.id}
             |> AccountDeletionWorker.new()
             |> Oban.insert() do
        conn
        |> UserAuth.clear_workos_session()
        |> put_flash(
          :info,
          "Account deletion has started. Your sessions and connected accounts are blocked."
        )
        |> redirect(to: ~p"/users/log-in")
      else
        {:error, _reason} ->
          conn
          |> put_flash(:error, "Account deletion could not be started. Please try again.")
          |> redirect(to: ~p"/users/settings")
      end
    else
      redirect_to_reauthentication(conn)
    end
  end

  defp redirect_to_reauthentication(conn) do
    conn
    |> put_flash(:error, "Please confirm your identity before deleting your account.")
    |> redirect(
      to: ~p"/auth/sign-in?#{[max_age: @fresh_auth_minutes * 60, return_to: "/users/settings"]}"
    )
  end
end
