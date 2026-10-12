defmodule Hermitscale.WorkOS.SessionTest do
  use ExUnit.Case, async: false

  alias Hermitscale.WorkOS.Session
  alias Hermitscale.WorkOSTest.{Client, JWTVerifier}

  import Hermitscale.WorkOS.SessionFixtures

  setup do
    start_supervised!({Client, %{}})
    previous = Application.get_env(:hermitscale, Session, [])
    Application.put_env(:hermitscale, Session, client: Client, jwt_verifier: JWTVerifier)
    on_exit(fn -> Application.put_env(:hermitscale, Session, previous) end)
    :ok
  end

  describe "create/1" do
    test "verifies WorkOS identity and seals tokens without persistence" do
      assert {:ok, authentication} = Session.create(authentication_fixture())
      refute authentication.sealed_session =~ "refresh_secret"
      assert authentication.current_scope.user.id == "user_workos"
      assert authentication.current_scope.organization.id == "org_workos"
      assert authentication.current_scope.membership.role == "admin"
      assert authentication.current_scope.membership.permissions == ["workflow:write"]
      assert authentication.session.id == "session_workos"
    end

    test "rejects a mismatched user, expired JWT and missing refresh token" do
      assert {:error, _} = Session.create(authentication_fixture(%{"sub" => "another_user"}))
      assert {:error, _} = Session.create(authentication_fixture(%{"exp" => 1}))
      assert {:error, _} = Session.create(Map.delete(authentication_fixture(), "refresh_token"))
    end

    test "leaves organizationless sessions without a tenant" do
      assert {:ok, authentication} = Session.create(authentication_fixture(%{"org_id" => nil}))
      assert authentication.current_scope.organization == nil
      assert authentication.current_scope.membership == nil
    end
  end

  describe "authenticate/2" do
    test "authenticates a fresh encrypted session without an API request" do
      {:ok, created} = Session.create(authentication_fixture())
      assert {:ok, authentication} = Session.authenticate(created.sealed_session)
      assert authentication.current_scope == created.current_scope
      assert authentication.sealed_session == created.sealed_session
      assert Client.calls() == []
    end

    test "rejects malformed and tampered sessions" do
      {:ok, created} = Session.create(authentication_fixture())

      assert {:error, :invalid_session} =
               Session.authenticate(created.sealed_session <> "tampered")

      assert {:error, :invalid_session} = Session.authenticate(nil)
      assert {:error, :invalid_session} = Session.authenticate("invalid")
    end

    test "enforces original browser lifetime even when sealed token and WorkOS JWT are fresh" do
      previous = Application.fetch_env!(:hermitscale, Session)
      Application.put_env(:hermitscale, Session, Keyword.put(previous, :max_age_seconds, 60))
      stale_session = expired_browser_session_fixture()

      assert {:error, :invalid_session} = Session.authenticate(stale_session)
      assert Client.calls() == []
    end

    test "refreshes tokens and derives authorization from replacement JWT" do
      {:ok, created} =
        Session.create(authentication_fixture(%{"exp" => System.system_time(:second) + 10}))

      replacement = authentication_fixture(%{"role" => "member", "permissions" => []})

      Client.put_response(
        :authenticate_with_refresh_token,
        {:ok, Map.put(replacement, "refresh_token", "rotated")}
      )

      metadata = %{ip_address: "127.0.0.1"}
      assert {:ok, authentication} = Session.authenticate(created.sealed_session, metadata)
      assert authentication.sealed_session != created.sealed_session
      assert authentication.current_scope.membership.role == "member"
      assert authentication.current_scope.membership.permissions == []

      assert [{:authenticate_with_refresh_token, ["refresh_secret", "org_workos", ^metadata]}] =
               Client.calls()

      assert {:ok, _} = Session.authenticate(authentication.sealed_session)
    end

    test "rejects refresh responses that change user, session, or organization" do
      {:ok, created} =
        Session.create(authentication_fixture(%{"exp" => System.system_time(:second) + 10}))

      for overrides <- [
            %{"sub" => "another_user"},
            %{"sid" => "another_session"},
            %{"org_id" => "another_org"}
          ] do
        Client.put_response(
          :authenticate_with_refresh_token,
          {:ok, authentication_fixture(overrides)}
        )

        assert {:error, :invalid_session} = Session.authenticate(created.sealed_session)
      end
    end

    test "returns temporary failure without authenticating stale claims" do
      {:ok, created} =
        Session.create(authentication_fixture(%{"exp" => System.system_time(:second) + 10}))

      Client.put_response(:authenticate_with_refresh_token, {:error, :unavailable})
      assert {:error, :unavailable} = Session.authenticate(created.sealed_session)
      Client.put_response(:authenticate_with_refresh_token, {:error, :invalid_grant})
      assert {:error, :invalid_session} = Session.authenticate(created.sealed_session)
    end
  end

  describe "logout/2" do
    test "revokes the remote WorkOS session and obtains its logout URL" do
      {:ok, created} = Session.create(authentication_fixture())
      assert {:ok, url} = Session.logout(created.sealed_session, "http://localhost:4000")
      assert url =~ "session_workos"

      assert [
               {:revoke_session, ["session_workos"]},
               {:logout_url, ["session_workos", "http://localhost:4000"]}
             ] = Client.calls()
    end

    test "reports WorkOS revocation failures without claiming remote logout succeeded" do
      {:ok, created} = Session.create(authentication_fixture())
      Client.put_response(:revoke_session, {:error, :unavailable})
      assert {:error, :unavailable} = Session.logout(created.sealed_session)
      assert [{:revoke_session, ["session_workos"]}] = Client.calls()
    end

    test "rejects invalid sessions without remote calls" do
      assert {:error, :invalid_session} = Session.logout("invalid")
      assert Client.calls() == []
    end
  end
end
