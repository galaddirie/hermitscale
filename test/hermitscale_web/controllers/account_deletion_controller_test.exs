defmodule HermitscaleWeb.AccountDeletionControllerTest do
  use HermitscaleWeb.ConnCase, async: true

  alias Hermitscale.Accounts
  alias Hermitscale.Accounts.AccountDeletionWorker
  alias Hermitscale.Repo

  import Hermitscale.AccountsFixtures

  test "requires fresh WorkOS authentication and schedules the durable saga", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)

    conn = delete(conn, ~p"/users/account")

    assert redirected_to(conn) == "/users/log-in"
    refute get_session(conn, :auth_session_token)
    assert Repo.get!(Accounts.User, user.id).deletion_pending_at

    assert %Oban.Job{
             args: %{"user_id" => user_id},
             worker: "Hermitscale.Accounts.AccountDeletionWorker"
           } = Repo.one!(Oban.Job)

    assert user_id == user.id
    assert AccountDeletionWorker.new(%{"user_id" => user.id}).valid?
  end

  test "redirects a stale session through AuthKit reauthentication", %{conn: conn} do
    user = user_fixture()

    conn =
      log_in_user(conn, user,
        token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
      )

    conn = delete(conn, ~p"/users/account")

    assert redirected_to(conn) ==
             "/auth/sign-in?max_age=600&return_to=%2Fusers%2Fsettings"

    assert Repo.get!(Accounts.User, user.id).deletion_pending_at == nil
    assert Repo.aggregate(Oban.Job, :count) == 0
  end
end
