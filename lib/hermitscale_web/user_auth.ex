defmodule HermitscaleWeb.UserAuth do
  @moduledoc "Browser and LiveView authentication through the configured identity provider."
  use HermitscaleWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Hermitscale.{Auth, Authorization}
  alias Hermitscale.Accounts.Scope
  alias HermitscaleWeb.SessionHandoffs

  @dependency_errors [:unavailable, :rate_limited, :invalid_response, :invalid_jwks]

  @doc "Verifies the opaque browser session and its active organization membership."
  def fetch_current_scope_for_user(conn, _opts) do
    case get_session(conn, :sealed_session) do
      nil ->
        assign(conn, :current_scope, nil)

      sealed_session ->
        case authenticate_session(sealed_session, request_metadata(conn)) do
          {:ok, authentication} ->
            conn
            |> put_session(:sealed_session, authentication.sealed_session)
            |> put_session(:live_socket_id, Auth.socket_topic(authentication.session))
            |> assign(:current_scope, authentication.current_scope)

          {:error, reason} when reason in @dependency_errors ->
            conn
            |> assign(:current_scope, nil)
            |> assign(:auth_error, reason)

          {:error, _reason} ->
            conn
            |> delete_session(:sealed_session)
            |> delete_session(:live_socket_id)
            |> assign(:current_scope, nil)
        end
    end
  end

  @doc "Requires a provider-verified user and active organization at HTTP entry."
  def require_authenticated_user(%{assigns: %{current_scope: %Scope{}}} = conn, _opts),
    do: conn

  def require_authenticated_user(conn, _opts) do
    conn
    |> put_flash(:error, "Sign in to open your conversations.")
    |> redirect(to: ~p"/auth/login")
    |> halt()
  end

  @doc "Verifies authentication and current directory membership without local identity records."
  def authenticate_session(sealed_session, metadata \\ %{}) do
    with {:ok, authentication} <- Auth.authenticate(sealed_session, metadata),
         {:ok, authentication} <- verify_membership(authentication) do
      {:ok, authentication}
    end
  end

  @doc "Revalidates organization membership, retaining the provider's user profile."
  def verify_membership(
        %{current_scope: %Scope{organization: %{id: _id}} = scope} = authentication
      ) do
    with {:ok, verified_scope} <-
           Authorization.execution_scope(Scope.execution_context(scope, [])) do
      verified_scope = %{verified_scope | user: scope.user, organization: scope.organization}
      {:ok, %{authentication | current_scope: verified_scope}}
    end
  end

  def verify_membership(%{current_scope: %Scope{organization: nil}}),
    do: {:error, :execution_actor_ineligible}

  @doc "Renews the browser session after the sign-in transaction has been verified."
  def log_in(conn, authentication) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:sealed_session, authentication.sealed_session)
    |> put_session(:live_socket_id, Auth.socket_topic(authentication.session))
  end

  @doc "Clears browser authority and disconnects LiveViews for the provider session."
  def clear_browser_session(conn) do
    case get_session(conn, :live_socket_id) do
      nil -> :ok
      topic -> HermitscaleWeb.Endpoint.broadcast(topic, "disconnect", %{})
    end

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  @doc "Verifies browser authority on LiveView mount and every reconnect."
  def on_mount(:require_authenticated, params, session, socket) do
    socket = mount_current_scope(socket, session)

    case socket.assigns.current_scope do
      %Scope{} ->
        case socket.assigns.auth_session_refresh do
          nil ->
            {:cont, socket}

          sealed_session ->
            case SessionHandoffs.create(
                   session["sealed_session"],
                   sealed_session,
                   SessionHandoffs,
                   refresh_return_to(params, socket)
                 ) do
              {:ok, nonce} ->
                {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/auth/session-refresh/#{nonce}")}

              {:error, :handoff_capacity} ->
                {:halt,
                 socket
                 |> Phoenix.LiveView.put_flash(
                   :error,
                   "Your session needs to be refreshed. Please sign in again."
                 )
                 |> Phoenix.LiveView.redirect(to: ~p"/auth/login")}
            end
        end

      nil ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "Sign in to open your conversations.")
         |> Phoenix.LiveView.redirect(to: ~p"/auth/login")}
    end
  end

  def on_mount(:mount_current_scope, _params, session, socket),
    do: {:cont, mount_current_scope(socket, session)}

  defp refresh_return_to(params, %{view: HermitscaleWeb.AppLive, assigns: assigns}) do
    base = uuid_path(params, "/apps")

    case {Map.get(assigns, :live_action), params} do
      {:build, %{"id" => _id}} when base != "/apps" ->
        base <> "/build"

      {:deployment, %{"deployment_id" => deployment}} when base != "/apps" ->
        case Ecto.UUID.cast(deployment) do
          {:ok, id} -> base <> "/deployments/" <> id
          :error -> base
        end

      _other ->
        base
    end
  end

  defp refresh_return_to(%{"id" => id}, %{view: HermitscaleWeb.WorkflowLive}) do
    if is_binary(id) and Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_:-]{0,127}\z/, id),
      do: "/workflows/" <> id,
      else: "/workflows"
  end

  defp refresh_return_to(_params, %{view: HermitscaleWeb.WorkflowLive}), do: "/workflows"
  defp refresh_return_to(params, _socket), do: uuid_path(params, "/agents")

  defp uuid_path(%{"id" => id}, prefix) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> prefix <> "/" <> id
      :error -> prefix
    end
  end

  defp uuid_path(_params, prefix), do: prefix

  defp mount_current_scope(socket, session) do
    {scope, replacement} =
      case Map.get(session, "sealed_session") do
        nil ->
          {nil, nil}

        sealed_session ->
          case authenticate_session(sealed_session) do
            {:ok, authentication} ->
              replacement =
                if Plug.Crypto.secure_compare(sealed_session, authentication.sealed_session),
                  do: nil,
                  else: authentication.sealed_session

              {authentication.current_scope, replacement}

            {:error, _reason} ->
              {nil, nil}
          end
      end

    Phoenix.Component.assign(socket, current_scope: scope, auth_session_refresh: replacement)
  end

  @doc "Returns bounded provider request metadata without credentials."
  def request_metadata(conn) do
    metadata = %{ip_address: conn.remote_ip |> :inet.ntoa() |> to_string()}

    case get_req_header(conn, "user-agent") do
      [user_agent | _rest] -> Map.put(metadata, :user_agent, String.slice(user_agent, 0, 512))
      [] -> metadata
    end
  end
end
