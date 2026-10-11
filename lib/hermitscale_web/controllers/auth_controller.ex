defmodule HermitscaleWeb.AuthController do
  use HermitscaleWeb, :controller

  alias Hermitscale.Accounts
  alias Hermitscale.WorkOS.{Client, Session, State}
  alias HermitscaleWeb.UserAuth

  def sign_in(conn, params) do
    return_to =
      params["return_to"] ||
        get_session(conn, :user_return_to) ||
        UserAuth.signed_in_path(conn)

    return_to = valid_return_to_or_default(return_to)

    with {:ok, state} <- State.issue(return_to),
         {:ok, authorization_url} <-
           client().authorization_url(state,
             max_age: max_age(params["max_age"]),
             screen_hint: screen_hint(params["screen_hint"])
           ) do
      redirect(conn, external: authorization_url)
    else
      {:error, _reason} ->
        conn
        |> put_flash(:error, "Sign in is temporarily unavailable. Please try again.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def callback(conn, %{"code" => code, "state" => state})
      when is_binary(code) and is_binary(state) do
    with {:ok, return_to} <- State.consume(state),
         {:ok, authentication} <-
           client().authenticate_with_code(code, UserAuth.request_metadata(conn)),
         {:ok, verified} <- Session.verify_authentication(authentication),
         {:ok, user} <- Accounts.upsert_from_workos(verified.workos_user),
         {:ok, local_session} <- Session.create_verified(user, verified) do
      UserAuth.put_workos_session(
        conn,
        local_session.handle,
        local_session.session,
        return_to
      )
    else
      {:error, :email_conflict} ->
        conn
        |> put_flash(
          :error,
          "This identity needs support review before it can be linked safely."
        )
        |> redirect(to: ~p"/users/log-in")

      {:error, :deletion_pending} ->
        conn
        |> put_flash(:error, "This account is pending deletion and cannot sign in.")
        |> redirect(to: ~p"/users/log-in")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "We could not complete sign in. Please start again.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "The sign-in response was incomplete. Please start again.")
    |> redirect(to: ~p"/users/log-in")
  end

  def delete(conn, _params) do
    return_to = url(~p"/users/log-in")

    logout_url =
      case UserAuth.session_handle(conn) do
        handle when is_binary(handle) ->
          case Session.logout(handle, return_to) do
            {:ok, url} -> url
            {:error, _reason} -> nil
          end

        _missing ->
          nil
      end

    conn =
      conn
      |> UserAuth.clear_workos_session()
      |> put_flash(:info, "You have been logged out.")

    case logout_url do
      url when is_binary(url) -> redirect(conn, external: url)
      nil -> redirect(conn, to: ~p"/users/log-in")
    end
  end

  defp valid_return_to_or_default(return_to) do
    case State.validate_return_to(return_to) do
      :ok -> return_to
      {:error, _reason} -> "/"
    end
  end

  defp max_age(value) when is_binary(value) do
    case Integer.parse(value) do
      {age, ""} when age in 0..86_400 -> age
      _other -> nil
    end
  end

  defp max_age(_value), do: nil

  defp screen_hint(value) when value in ["sign-up", "sign-in"], do: value
  defp screen_hint(_value), do: nil

  defp client do
    Application.get_env(:hermitscale, __MODULE__, [])[:client] || Client
  end
end
