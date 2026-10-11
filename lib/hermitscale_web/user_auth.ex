defmodule HermitscaleWeb.UserAuth do
  @moduledoc """
  Phoenix integration for WorkOS-bounded application sessions.

  The browser session contains only an opaque random handle. The WorkOS
  access and refresh tokens remain encrypted in `auth_sessions`.
  """

  use HermitscaleWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Hermitscale.Accounts.Scope
  alias Hermitscale.WorkOS.Session

  @session_key :auth_session_token
  @fresh_auth_minutes 10

  @doc """
  Establishes a verified WorkOS session and renews the Phoenix cookie session.
  """
  def put_workos_session(conn, handle, auth_session, return_to \\ nil)
      when is_binary(handle) do
    destination = return_to || signed_in_path(conn)

    conn
    |> renew_session()
    |> put_session(@session_key, handle)
    |> put_session(:live_socket_id, Session.socket_topic(auth_session))
    |> redirect(to: destination)
  end

  @doc """
  Clears all local browser session data and renews the session identifier.
  """
  def clear_workos_session(conn) do
    if live_socket_id = get_session(conn, :live_socket_id) do
      HermitscaleWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    renew_session(conn)
  end

  @doc """
  Authenticates the opaque session handle and assigns the active local scope.

  An invalid or revoked handle is cleared. A refresh-time WorkOS outage fails
  the request closed with a retryable 503 while preserving the server-side row
  so authentication can resume after recovery.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    case get_session(conn, @session_key) do
      handle when is_binary(handle) ->
        authenticate_conn(conn, handle)

      _missing ->
        assign(conn, :current_scope, nil)
    end
  end

  defp authenticate_conn(conn, handle) do
    case Session.authenticate(handle, request_metadata(conn)) do
      {:ok, authentication} ->
        conn
        |> assign(:current_scope, authentication.current_scope)
        |> assign(:auth_session, authentication.session)

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
        |> renew_session()
        |> assign(:current_scope, nil)
    end
  end

  @doc """
  Handles mounting and authentication for the router's two LiveView sessions.
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if authenticated?(socket) do
      {:cont, socket}
    else
      {:halt, redirect_to_login(socket)}
    end
  end

  def on_mount(:require_sudo_mode, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if authenticated?(socket) &&
         Session.fresh?(socket.assigns.auth_session, @fresh_auth_minutes) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(
          :error,
          "Please confirm your identity before continuing."
        )
        |> Phoenix.LiveView.redirect(
          to:
            ~p"/auth/sign-in?#{[max_age: @fresh_auth_minutes * 60, return_to: "/users/settings"]}"
        )

      {:halt, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    authentication = authenticate_live_session(session)

    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      case authentication do
        {:ok, authentication} -> authentication.current_scope
        {:error, _reason} -> nil
      end
    end)
    |> Phoenix.Component.assign_new(:auth_session, fn ->
      case authentication do
        {:ok, authentication} -> authentication.session
        {:error, _reason} -> nil
      end
    end)
  end

  defp authenticate_live_session(%{"auth_session_token" => handle}) when is_binary(handle) do
    Session.authenticate(handle)
  end

  defp authenticate_live_session(_session), do: {:error, :invalid_session}

  defp authenticated?(socket) do
    match?(%Scope{user: %{}}, socket.assigns[:current_scope]) &&
      not is_nil(socket.assigns[:auth_session])
  end

  defp redirect_to_login(socket) do
    socket
    |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
    |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")
  end

  @doc "Returns the local path used after a successful login."
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: %Scope{user: %{}}}}),
    do: ~p"/users/settings"

  def signed_in_path(_conn), do: ~p"/"

  @doc """
  Plug for routes that require a verified WorkOS session.
  """
  def require_authenticated_user(conn, _opts) do
    if match?(%Scope{user: %{}}, conn.assigns[:current_scope]) do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  @doc """
  Extracts request metadata accepted by WorkOS session exchange endpoints.
  """
  def request_metadata(%Plug.Conn{} = conn) do
    %{
      ip_address: conn.remote_ip |> :inet.ntoa() |> to_string(),
      user_agent: get_req_header(conn, "user-agent") |> List.first()
    }
  end

  @doc false
  def session_handle(%Plug.Conn{} = conn), do: get_session(conn, @session_key)

  @doc false
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      HermitscaleWeb.Endpoint.broadcast(
        "users_sessions:#{Base.url_encode64(token)}",
        "disconnect",
        %{}
      )
    end)
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
