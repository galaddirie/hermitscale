defmodule HermitscaleWeb.AuthControllerTest do
  use HermitscaleWeb.ConnCase, async: false

  alias Hermitscale.Accounts
  alias Hermitscale.Repo
  alias Hermitscale.WorkOS.{AuthSession, State}
  alias Hermitscale.WorkOSTest.Client
  alias HermitscaleWeb.AuthController

  import Hermitscale.AccountsFixtures

  setup do
    start_supervised!({Client, %{}})
    previous = Application.get_env(:hermitscale, AuthController, [])
    Application.put_env(:hermitscale, AuthController, Keyword.put(previous, :client, Client))

    on_exit(fn -> Application.put_env(:hermitscale, AuthController, previous) end)
  end

  test "stores the return target server-side and refuses an external redirect", %{conn: conn} do
    conn = get(conn, ~p"/auth/sign-in?return_to=https%3A%2F%2Fevil.example%2Fsteal")

    assert redirected_to(conn) =~ "https://api.workos.com/authorize"

    assert [
             {:authorization_url, [state, [max_age: nil, screen_hint: nil]]}
           ] = Client.calls()

    assert {:ok, "/"} = State.consume(state)
  end

  test "callback validates state, provisions by WorkOS user ID, and renews the session", %{
    conn: conn
  } do
    assert {:ok, state} = State.issue("/users/settings")
    now = System.system_time(:second)
    workos_user_id = "user_callback_123"
    session_id = "session_callback_123"

    claims = %{
      "sub" => workos_user_id,
      "sid" => session_id,
      "iat" => now,
      "auth_time" => now,
      "exp" => now + 3_600
    }

    Client.put_response(
      :authenticate_with_code,
      {:ok,
       %{
         "access_token" => Jason.encode!(claims),
         "refresh_token" => "refresh-callback-secret",
         "user" => %{
           "id" => workos_user_id,
           "email" => "callback@example.com",
           "email_verified" => true,
           "first_name" => "Callback",
           "last_name" => "User",
           "created_at" => "2026-07-26T18:00:00.000000Z",
           "updated_at" => "2026-07-26T18:00:00.000000Z"
         }
       }}
    )

    conn =
      conn
      |> init_test_session(%{remove_me: "stale"})
      |> get(~p"/auth/workos/callback?code=code_123&state=#{state}")

    assert redirected_to(conn) == "/users/settings"
    assert is_binary(get_session(conn, :auth_session_token))
    refute get_session(conn, :remove_me)

    user = Accounts.get_user_by_workos_id(workos_user_id)
    assert user.email == "callback@example.com"
    assert [%Accounts.Organization{personal: true}] = Accounts.list_user_organizations(user)

    assert %AuthSession{
             user_id: user_id,
             workos_session_id: ^session_id,
             revoked_at: nil
           } = Repo.one!(AuthSession)

    assert user_id == user.id
  end

  test "never links a callback to a different local user by email", %{conn: conn} do
    existing = user_fixture()
    assert {:ok, state} = State.issue("/")
    now = System.system_time(:second)

    claims = %{
      "sub" => "different_workos_user",
      "sid" => "session_conflict",
      "iat" => now,
      "auth_time" => now,
      "exp" => now + 3_600
    }

    Client.put_response(
      :authenticate_with_code,
      {:ok,
       %{
         "access_token" => Jason.encode!(claims),
         "refresh_token" => "refresh-conflict",
         "user" => %{
           "id" => "different_workos_user",
           "email" => existing.email,
           "email_verified" => true,
           "created_at" => "2026-07-26T18:00:00.000000Z",
           "updated_at" => "2026-07-26T18:00:00.000000Z"
         }
       }}
    )

    conn = get(conn, ~p"/auth/workos/callback?code=code_conflict&state=#{state}")

    assert redirected_to(conn) == "/users/log-in"
    refute get_session(conn, :auth_session_token)
    assert Accounts.get_user_by_workos_id("different_workos_user") == nil
    assert Repo.aggregate(AuthSession, :count) == 0
  end

  test "callback state cannot be replayed", %{conn: conn} do
    assert {:ok, state} = State.issue("/")
    now = System.system_time(:second)

    claims = %{
      "sub" => "user_replay",
      "sid" => "session_replay",
      "iat" => now,
      "auth_time" => now,
      "exp" => now + 3_600
    }

    Client.put_response(
      :authenticate_with_code,
      {:ok,
       %{
         "access_token" => Jason.encode!(claims),
         "refresh_token" => "refresh-replay",
         "user" => %{
           "id" => "user_replay",
           "email" => "replay@example.com",
           "email_verified" => true,
           "created_at" => "2026-07-26T18:00:00.000000Z",
           "updated_at" => "2026-07-26T18:00:00.000000Z"
         }
       }}
    )

    first = get(conn, ~p"/auth/workos/callback?code=code_replay&state=#{state}")
    assert redirected_to(first) == "/"

    replay = get(recycle(conn), ~p"/auth/workos/callback?code=code_replay&state=#{state}")
    assert redirected_to(replay) == "/users/log-in"
    assert Repo.aggregate(AuthSession, :count) == 1

    assert Enum.count(Client.calls(), fn {operation, _args} ->
             operation == :authenticate_with_code
           end) == 1
  end
end
