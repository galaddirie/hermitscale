defmodule HermitscaleWeb.ConnectedAccountController do
  use HermitscaleWeb, :controller

  alias Hermitscale.Integrations.ConnectedAccounts

  def create(conn, %{"provider" => provider} = params) do
    sharing_mode =
      params
      |> get_in(["connection", "sharing_mode"])
      |> sharing_mode()

    return_to = url(~p"/users/settings/connected-accounts")

    with mode when mode in [:private, :organization] <- sharing_mode,
         {:ok, %{url: authorization_url}} <-
           ConnectedAccounts.begin_connect(
             conn.assigns.current_scope,
             provider,
             mode,
             return_to
           ),
         true <- ConnectedAccounts.authorization_url_allowed?(authorization_url) do
      redirect(conn, external: authorization_url)
    else
      false ->
        conn
        |> put_flash(:error, "The provider returned an unsafe authorization URL.")
        |> redirect(to: ~p"/users/settings/connected-accounts")

      {:error, :unauthorized} ->
        conn
        |> put_flash(:error, "You cannot grant that connection to this organization.")
        |> redirect(to: ~p"/users/settings/connected-accounts")

      _error ->
        conn
        |> put_flash(:error, "The connection could not be started. Please try again.")
        |> redirect(to: ~p"/users/settings/connected-accounts")
    end
  end

  def delete(conn, %{"provider" => provider}) do
    case ConnectedAccounts.disconnect(conn.assigns.current_scope, provider) do
      {:ok, _account} ->
        conn
        |> put_flash(
          :info,
          "Disconnected from Hermitscale. You may still need to revoke the app at the provider."
        )
        |> redirect(to: ~p"/users/settings/connected-accounts")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "That connected account was not found.")
        |> redirect(to: ~p"/users/settings/connected-accounts")

      {:error, _reason} ->
        conn
        |> put_flash(
          :error,
          "New token use is blocked, but WorkOS has not confirmed deletion yet. Retry shortly."
        )
        |> redirect(to: ~p"/users/settings/connected-accounts")
    end
  end

  def update(conn, %{"provider" => provider} = params) do
    sharing_mode =
      params
      |> get_in(["connection", "sharing_mode"])
      |> sharing_mode()

    case sharing_mode do
      mode when mode in [:private, :organization] ->
        update_sharing(conn, provider, mode)

      _invalid ->
        conn
        |> put_flash(:error, "Choose a valid connection access level.")
        |> redirect(to: ~p"/users/settings/connected-accounts")
    end
  end

  defp update_sharing(conn, provider, mode) do
    case ConnectedAccounts.set_sharing(conn.assigns.current_scope, provider, mode) do
      {:ok, _account} ->
        conn
        |> put_flash(:info, "Connection access updated.")
        |> redirect(to: ~p"/users/settings/connected-accounts")

      {:error, :unauthorized} ->
        conn
        |> put_flash(:error, "Only an organization owner or admin can share this connection.")
        |> redirect(to: ~p"/users/settings/connected-accounts")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "That connected account was not found.")
        |> redirect(to: ~p"/users/settings/connected-accounts")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Connection access could not be updated.")
        |> redirect(to: ~p"/users/settings/connected-accounts")
    end
  end

  defp sharing_mode("private"), do: :private
  defp sharing_mode("organization"), do: :organization
  defp sharing_mode(_value), do: nil
end
