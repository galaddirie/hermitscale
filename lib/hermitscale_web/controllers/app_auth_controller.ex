defmodule HermitscaleWeb.AppAuthController do
  @moduledoc """
  Identity-provider callback for org apps. Verifies membership in the app's
  organization, then hands a short-lived token back to the app host.
  """

  use HermitscaleWeb, :controller

  alias Hermitscale.Apps
  alias HermitscaleWeb.AppProxy

  def callback(conn, %{"code" => code, "state" => state})
      when is_binary(code) and is_binary(state) do
    with {:ok, login} <- AppProxy.verify_token(:login, state),
         %Apps.App{} = app <- Apps.get_app(login.app_id),
         {:ok, user} <- Apps.sign_in_visitor(app, code, request_metadata(conn)) do
      token = AppProxy.sign_token(:handoff, Map.put(login, :user, user))

      redirect(conn,
        external: Apps.app_url(app) <> "/_hermitscale/session?" <> URI.encode_query(token: token)
      )
    else
      _failure -> sign_in_failed(conn)
    end
  end

  def callback(conn, _params), do: sign_in_failed(conn)

  defp sign_in_failed(conn), do: conn |> put_status(:forbidden) |> text("Sign-in failed")

  defp request_metadata(conn) do
    %{
      ip_address: conn.remote_ip |> :inet.ntoa() |> to_string(),
      user_agent: conn |> get_req_header("user-agent") |> List.first("")
    }
  end
end
