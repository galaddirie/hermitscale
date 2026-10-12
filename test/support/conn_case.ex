defmodule HermitscaleWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use HermitscaleWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint HermitscaleWeb.Endpoint

      use HermitscaleWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import HermitscaleWeb.ConnCase
    end
  end

  setup tags do
    Hermitscale.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper for a verified WorkOS login.

      setup :log_in_workos_user

  It stores an updated connection and a WorkOS user in the
  test context.
  """
  def log_in_workos_user(%{conn: conn} = context) do
    user = Hermitscale.AccountsFixtures.user_fixture()
    scope = Hermitscale.AccountsFixtures.user_scope_fixture(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])
      |> Keyword.put(:org_id, scope.organization.id)

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  Logs the given `user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user, opts \\ []) do
    session =
      Hermitscale.AccountsFixtures.workos_session_fixture(user,
        org_id: opts[:org_id],
        authenticated_at: opts[:token_authenticated_at] || DateTime.utc_now(:second)
      )

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Test.put_req_cookie("_hermitscale_workos", session.sealed_session)
  end
end
