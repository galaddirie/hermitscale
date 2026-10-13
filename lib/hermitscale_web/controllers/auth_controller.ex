defmodule HermitscaleWeb.AuthController do
  use HermitscaleWeb, :controller

  alias Hermitscale.Auth
  alias HermitscaleWeb.UserAuth
  alias HermitscaleWeb.SessionHandoffs

  @state_max_age 600

  def login(conn, _params) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    with {:ok, url} <- Auth.authorization_url(state),
         :ok <- validate_provider_url(url) do
      conn
      |> put_session(:oauth_state, %{nonce: state, issued_at: System.system_time(:second)})
      |> redirect(external: url)
    else
      {:error, _reason} -> auth_failure(delete_session(conn, :oauth_state))
    end
  end

  def callback(conn, params) do
    transaction = get_session(conn, :oauth_state)
    conn = delete_session(conn, :oauth_state)

    with :ok <- verify_transaction(transaction, params),
         {:ok, authentication} <- Auth.sign_in(params["code"], UserAuth.request_metadata(conn)),
         {:ok, authentication} <- UserAuth.verify_membership(authentication) do
      conn
      |> UserAuth.log_in(authentication)
      |> redirect(to: ~p"/agents")
    else
      {:error, _reason} -> auth_failure(conn)
    end
  end

  def logout(conn, _params) do
    result = Auth.logout(get_session(conn, :sealed_session))
    conn = UserAuth.clear_browser_session(conn)

    with {:ok, url} <- result,
         :ok <- validate_provider_url(url) do
      redirect(conn, external: url)
    else
      {:error, :invalid_session} ->
        redirect(conn, to: ~p"/")

      {:error, _reason} ->
        conn
        |> put_flash(
          :error,
          "You are signed out here. The identity provider could not complete sign-out."
        )
        |> redirect(to: ~p"/")
    end
  end

  def session_refresh(conn, %{"nonce" => nonce}) do
    with {:ok, handoff} <-
           SessionHandoffs.consume(nonce, get_session(conn, :sealed_session)),
         {:ok, authentication} <-
           UserAuth.authenticate_session(handoff.sealed_session, UserAuth.request_metadata(conn)) do
      conn
      |> UserAuth.log_in(authentication)
      |> redirect(to: handoff.return_to)
    else
      {:error, _reason} -> auth_failure(conn)
    end
  end

  defp verify_transaction(
         %{nonce: nonce, issued_at: issued_at},
         %{"state" => state, "code" => code}
       )
       when is_binary(nonce) and is_binary(state) and is_integer(issued_at) and
              is_binary(code) and code != "" do
    age = System.system_time(:second) - issued_at

    case age >= 0 and age <= @state_max_age and Plug.Crypto.secure_compare(nonce, state) do
      true -> :ok
      false -> {:error, :invalid_oauth_transaction}
    end
  end

  defp verify_transaction(_transaction, _params), do: {:error, :invalid_oauth_transaction}

  defp validate_provider_url(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}}
      when is_binary(host) and host != "" ->
        :ok

      {:ok, _uri} ->
        {:error, :invalid_response}

      {:error, _reason} ->
        {:error, :invalid_response}
    end
  end

  defp validate_provider_url(_url), do: {:error, :invalid_response}

  defp auth_failure(conn) do
    conn
    |> put_flash(:error, "Sign-in could not be completed. Please try again.")
    |> redirect(to: ~p"/")
  end
end
