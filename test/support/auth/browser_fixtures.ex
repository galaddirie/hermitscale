defmodule HermitscaleWeb.BrowserAuthFixtures do
  @moduledoc false

  alias Hermitscale.Auth
  alias Hermitscale.AuthTest.Provider

  def setup_provider do
    previous = Application.fetch_env!(:hermitscale, Auth)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:hermitscale, Auth, previous) end)
    ExUnit.Callbacks.start_supervised!({Provider, %{}})
    Application.put_env(:hermitscale, Auth, provider: Provider)
    :ok
  end

  def authenticated_conn(conn) do
    {:ok, authentication} = Auth.sign_in("team-code")

    conn =
      Phoenix.ConnTest.init_test_session(conn, %{
        "sealed_session" => authentication.sealed_session,
        "live_socket_id" => Auth.socket_topic(authentication.session)
      })

    %{conn: conn, authentication: authentication, scope: authentication.current_scope}
  end
end
