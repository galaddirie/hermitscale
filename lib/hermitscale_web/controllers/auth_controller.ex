defmodule HermitscaleWeb.AuthController do
  use HermitscaleWeb, :controller

  alias Hermitscale.WorkOS.{Client, Session}
  alias HermitscaleWeb.UserAuth

  @state_lifetime_seconds 10 * 60

  def sign_in(conn, _params) do
    state = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    case client().authorization_url(state) do
      {:ok, authorization_url} ->
        conn
        |> put_session(:workos_oauth_state, %{
          "token" => state,
          "issued_at" => System.system_time(:second)
        })
        |> redirect(external: authorization_url)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Sign in is temporarily unavailable. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  def callback(conn, params) do
    pending_state = get_session(conn, :workos_oauth_state)
    conn = delete_session(conn, :workos_oauth_state)

    with :ok <- validate_state(params["state"], pending_state),
         code when is_binary(code) and code != "" <- params["code"],
         {:ok, authentication} <-
           client().authenticate_with_code(code, UserAuth.request_metadata(conn)),
         {:ok, authentication} <- Session.create(authentication) do
      UserAuth.put_workos_session(conn, authentication)
    else
      _error ->
        conn
        |> put_flash(:error, "We could not complete sign in. Please start again.")
        |> redirect(to: ~p"/")
    end
  end

  def delete(conn, _params) do
    logout_result = Session.logout(UserAuth.sealed_session(conn), url(~p"/"))

    conn =
      conn
      |> UserAuth.clear_workos_session()
      |> put_flash(:info, "You have been logged out.")

    case logout_result do
      {:ok, logout_url} -> redirect(conn, external: logout_url)
      {:error, _reason} -> redirect(conn, to: ~p"/")
    end
  end

  defp validate_state(state, %{"token" => expected, "issued_at" => issued_at})
       when is_binary(state) and is_binary(expected) and is_integer(issued_at) do
    age = System.system_time(:second) - issued_at

    case age in 0..@state_lifetime_seconds && Plug.Crypto.secure_compare(state, expected) do
      true -> :ok
      false -> {:error, :invalid_state}
    end
  end

  defp validate_state(_state, _pending_state), do: {:error, :invalid_state}

  defp client do
    Application.get_env(:hermitscale, __MODULE__, [])[:client] || Client
  end
end
