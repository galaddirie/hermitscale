defmodule HermitscaleWeb.UserAuth do
  @moduledoc "Phoenix integration for WorkOS sessions and request scopes."

  use HermitscaleWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Hermitscale.Accounts.Scope
  alias Hermitscale.WorkOS.Session

  @session_cookie "_hermitscale_workos"
  @cookie_max_age 30 * 24 * 60 * 60
  @max_sealed_session_bytes 3_800

  @doc "Stores the sealed WorkOS session in a renewed Phoenix browser session."
  def put_workos_session(conn, %{sealed_session: sealed_session})
      when byte_size(sealed_session) <= @max_sealed_session_bytes do
    conn
    |> renew_session()
    |> put_resp_cookie(@session_cookie, sealed_session, cookie_options())
    |> redirect(to: ~p"/")
  end

  def put_workos_session(conn, _authentication) do
    conn
    |> clear_workos_session()
    |> put_flash(:error, "We could not complete sign in. Please start again.")
    |> redirect(to: ~p"/")
  end

  @doc "Clears the browser session and renews the session identifier."
  def clear_workos_session(conn) do
    conn
    |> renew_session()
    |> delete_resp_cookie(@session_cookie, cookie_options())
  end

  @doc "Verifies WorkOS credentials and assigns the request's current scope."
  def fetch_current_scope_for_user(conn, _opts) do
    conn = fetch_cookies(conn)

    case sealed_session(conn) do
      session when is_binary(session) -> authenticate_conn(conn, session)
      _missing -> assign(conn, :current_scope, nil)
    end
  end

  defp authenticate_conn(conn, sealed_session) do
    case Session.authenticate(sealed_session, request_metadata(conn)) do
      {:ok, %{sealed_session: replacement} = authentication}
      when byte_size(replacement) <= @max_sealed_session_bytes ->
        conn
        |> maybe_rotate_cookie(sealed_session, replacement)
        |> assign(:current_scope, authentication.current_scope)
        |> assign(:auth_session, authentication.session)
        |> assign(:sealed_workos_session, replacement)

      {:ok, _oversized_session} ->
        conn
        |> clear_workos_session()
        |> assign(:current_scope, nil)

      {:error, :unavailable} ->
        conn
        |> assign(:current_scope, nil)
        |> send_resp(
          :service_unavailable,
          "Authentication is temporarily unavailable. Please try again."
        )
        |> halt()

      {:error, _reason} ->
        conn
        |> clear_workos_session()
        |> assign(:current_scope, nil)
    end
  end

  @doc "Requires a verified WorkOS scope before a controller action can run."
  def require_authenticated_user(%{assigns: %{current_scope: %Scope{user: %{}}}} = conn, _opts),
    do: conn

  def require_authenticated_user(conn, _opts) do
    conn
    |> put_flash(:error, "You must log in to access this page.")
    |> redirect(to: ~p"/auth/sign-in")
    |> halt()
  end

  @doc "Request metadata accepted by WorkOS authentication endpoints."
  def request_metadata(%Plug.Conn{} = conn) do
    %{
      ip_address: conn.remote_ip |> :inet.ntoa() |> to_string(),
      user_agent: get_req_header(conn, "user-agent") |> List.first()
    }
  end

  @doc false
  def sealed_session(%Plug.Conn{assigns: %{sealed_workos_session: session}}), do: session

  def sealed_session(%Plug.Conn{} = conn) do
    conn = fetch_cookies(conn)
    conn.cookies[@session_cookie]
  end

  defp maybe_rotate_cookie(conn, session, session), do: conn

  defp maybe_rotate_cookie(conn, _previous, replacement) do
    put_resp_cookie(conn, @session_cookie, replacement, cookie_options())
  end

  defp cookie_options do
    [
      http_only: true,
      same_site: "Lax",
      secure: Application.get_env(:hermitscale, :secure_cookies, false),
      max_age: @cookie_max_age,
      path: "/"
    ]
  end

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
