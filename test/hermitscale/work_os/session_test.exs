defmodule Hermitscale.WorkOS.SessionTest do
  use Hermitscale.DataCase, async: false

  alias Hermitscale.Repo
  alias Hermitscale.WorkOS.{AuthSession, Session, TokenCipher}
  alias Hermitscale.WorkOSTest.{Client, JWTVerifier}

  import Hermitscale.AccountsFixtures

  setup do
    start_supervised!({Client, %{}})

    previous = Application.get_env(:hermitscale, Session, [])

    Application.put_env(
      :hermitscale,
      Session,
      previous
      |> Keyword.put(:client, Client)
      |> Keyword.put(:jwt_verifier, JWTVerifier)
    )

    on_exit(fn -> Application.put_env(:hermitscale, Session, previous) end)
  end

  test "authenticates an opaque handle without contacting WorkOS while the JWT is fresh" do
    user = user_fixture()
    local_session = workos_session_fixture(user)

    assert {:ok, authentication} = Session.authenticate(local_session.handle)
    assert authentication.current_scope.user.id == user.id
    assert authentication.current_scope.organization.personal
    assert Client.calls() == []
  end

  test "serially rotates an expired session and atomically replaces both ciphertexts" do
    user = user_fixture()
    local_session = expired_session_fixture(user)
    now = System.system_time(:second)

    replacement_claims = %{
      "sub" => user.workos_user_id,
      "sid" => local_session.session.workos_session_id,
      "iat" => now,
      "auth_time" => now - 300,
      "exp" => now + 3_600
    }

    Client.put_response(
      :authenticate_with_refresh_token,
      {:ok,
       %{
         "access_token" => Jason.encode!(replacement_claims),
         "refresh_token" => "rotated-refresh-token"
       }}
    )

    assert {:ok, authentication} = Session.authenticate(local_session.handle)
    assert authentication.claims == replacement_claims

    rotated = Repo.get!(AuthSession, local_session.session.id)
    assert rotated.revoked_at == nil
    assert rotated.access_token_ciphertext != local_session.session.access_token_ciphertext
    assert rotated.refresh_token_ciphertext != local_session.session.refresh_token_ciphertext

    assert {:ok, "rotated-refresh-token"} =
             TokenCipher.decrypt(rotated.refresh_token_ciphertext, rotated.encryption_key_id)

    assert [
             {:authenticate_with_refresh_token, ["initial-refresh-token", nil, %{}]}
           ] = Client.calls()
  end

  test "preserves an expired local row during a retryable WorkOS outage" do
    user = user_fixture()
    local_session = expired_session_fixture(user)
    Client.put_response(:authenticate_with_refresh_token, {:error, :unavailable})

    assert {:error, :unavailable} = Session.authenticate(local_session.handle)

    persisted = Repo.get!(AuthSession, local_session.session.id)
    assert persisted.revoked_at == nil
    assert persisted.refresh_token_ciphertext == local_session.session.refresh_token_ciphertext
  end

  test "revokes a local row when WorkOS rejects the rotating refresh token" do
    user = user_fixture()
    local_session = expired_session_fixture(user)
    Client.put_response(:authenticate_with_refresh_token, {:error, :invalid_grant})

    assert {:error, :invalid_session} = Session.authenticate(local_session.handle)
    assert Repo.get!(AuthSession, local_session.session.id).revoked_at
  end

  test "revokes only sessions belonging to a removed organization membership" do
    user = user_fixture()
    shared = organization_fixture()
    organization_membership_fixture(user, shared)

    personal_session = workos_session_fixture(user)
    shared_session = workos_session_fixture(user, org_id: shared.id)

    assert {:ok, 1} = Session.revoke_for_user_organization(user.id, shared.id)
    refute Repo.get!(AuthSession, personal_session.session.id).revoked_at
    assert Repo.get!(AuthSession, shared_session.session.id).revoked_at
  end

  defp expired_session_fixture(user) do
    now = System.system_time(:second)
    session_id = "session_#{System.unique_integer([:positive])}"

    claims = %{
      "sub" => user.workos_user_id,
      "sid" => session_id,
      "iat" => now - 3_600,
      "auth_time" => now - 3_600,
      "exp" => now - 1
    }

    {:ok, local_session} =
      Session.create_verified(user, %{
        access_token: Jason.encode!(claims),
        refresh_token: "initial-refresh-token",
        claims: claims
      })

    local_session
  end
end
