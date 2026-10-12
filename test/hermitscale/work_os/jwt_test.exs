defmodule Hermitscale.WorkOS.JWTTest do
  use ExUnit.Case, async: false

  alias Hermitscale.WorkOS.JWT

  import Hermitscale.WorkOS.JWTFixtures
  alias Hermitscale.WorkOSTest.Client

  setup do
    start_supervised!({Client, %{}})

    previous = Application.get_env(:hermitscale, JWT)

    Application.put_env(
      :hermitscale,
      JWT,
      issuer: "https://api.workos.test",
      client_id: "client_123",
      client: Client,
      jwks_cache_ttl_seconds: 300
    )

    JWT.clear_cache()

    on_exit(fn ->
      JWT.clear_cache()
      Application.put_env(:hermitscale, JWT, previous)
    end)
  end

  test "verifies signature and strict identity/session claims" do
    {private_key, public_key} = rsa_key_fixture("kid_one")
    Client.put_response(:jwks, {:ok, %{"keys" => [public_key]}})

    now = System.system_time(:second)
    token = sign_fixture(private_key, claims_fixture(now), "kid_one")

    assert {:ok, claims} =
             JWT.verify(token,
               subject: "user_123",
               session_id: "session_123",
               now: now
             )

    assert claims["sub"] == "user_123"

    assert {:error, :invalid_subject} =
             JWT.verify(token, subject: "another_user", now: now)

    assert {:error, :invalid_session} =
             JWT.verify(token, session_id: "another_session", now: now)
  end

  test "rejects issuer, client, future-issued, and expired claims" do
    {private_key, public_key} = rsa_key_fixture("kid_claims")
    Client.put_response(:jwks, {:ok, %{"keys" => [public_key]}})
    now = System.system_time(:second)

    for claims <- [
          Map.put(claims_fixture(now), "iss", "https://attacker.example"),
          Map.put(claims_fixture(now), "client_id", "another_client"),
          Map.put(claims_fixture(now), "iat", now + 61),
          Map.put(claims_fixture(now), "exp", now)
        ] do
      assert {:error, _reason} =
               JWT.verify(sign_fixture(private_key, claims, "kid_claims"), now: now)
    end
  end

  test "derives the default WorkOS issuer from the configured client application" do
    {private_key, public_key} = rsa_key_fixture("kid_application_issuer")
    Client.put_response(:jwks, {:ok, %{"keys" => [public_key]}})

    config =
      :hermitscale
      |> Application.fetch_env!(JWT)
      |> Keyword.delete(:issuer)

    Application.put_env(:hermitscale, JWT, config)

    now = System.system_time(:second)

    claims =
      Map.put(
        claims_fixture(now),
        "iss",
        "https://api.workos.com/user_management/client_123"
      )

    assert {:ok, _claims} =
             private_key
             |> sign_fixture(claims, "kid_application_issuer")
             |> JWT.verify(now: now)

    other_client_claims =
      Map.put(
        claims,
        "iss",
        "https://api.workos.com/user_management/client_other"
      )

    assert {:error, :invalid_issuer} =
             private_key
             |> sign_fixture(other_client_claims, "kid_application_issuer")
             |> JWT.verify(now: now)
  end

  test "refreshes JWKS once for an unknown kid and accepts key rollover" do
    {first_private, first_public} = rsa_key_fixture("kid_old")
    {second_private, second_public} = rsa_key_fixture("kid_new")
    now = System.system_time(:second)

    Client.put_response(:jwks, {:ok, %{"keys" => [first_public]}})

    assert {:ok, _claims} =
             first_private
             |> sign_fixture(claims_fixture(now), "kid_old")
             |> JWT.verify(now: now)

    Client.put_response(:jwks, {:ok, %{"keys" => [first_public, second_public]}})

    assert {:ok, _claims} =
             second_private
             |> sign_fixture(claims_fixture(now), "kid_new")
             |> JWT.verify(now: now)

    assert [
             {:jwks, []},
             {:jwks, []}
           ] = Client.calls()
  end

  test "fails closed when a signing key remains unknown" do
    {_private_key, public_key} = rsa_key_fixture("known")
    {unknown_private, _unknown_public} = rsa_key_fixture("unknown")
    Client.put_response(:jwks, {:ok, %{"keys" => [public_key]}})
    now = System.system_time(:second)

    assert {:error, :unknown_signing_key} =
             unknown_private
             |> sign_fixture(claims_fixture(now), "unknown")
             |> JWT.verify(now: now)
  end

  test "rejects malformed signing keys as a dependency response error" do
    {private_key, public_key} = rsa_key_fixture("malformed")
    token = sign_fixture(private_key, claims_fixture(System.system_time(:second)), "malformed")

    for key <- [
          false,
          Map.delete(public_key, "n"),
          Map.put(public_key, "n", "not+base64"),
          Map.put(public_key, "e", ""),
          Map.put(public_key, "e", Base.url_encode64(<<0>>, padding: false)),
          Map.put(public_key, "kty", "oct"),
          Map.put(public_key, "use", "enc"),
          Map.put(public_key, "alg", "HS256")
        ] do
      JWT.clear_cache()
      Client.put_response(:jwks, {:ok, %{"keys" => [key]}})
      assert {:error, :invalid_jwks} = JWT.verify(token)
    end
  end

  test "malformed token payloads and signatures remain authentication errors" do
    {_private_key, public_key} = rsa_key_fixture("malformed_token")
    Client.put_response(:jwks, {:ok, %{"keys" => [public_key]}})

    header =
      Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "kid" => "malformed_token"}),
        padding: false
      )

    for token <- ["invalid", header <> ".!.!", header <> ".e30.", header <> ".W10.AA"] do
      assert {:error, _reason} = JWT.verify(token)
    end
  end

  test "configured adapter defects are visible instead of authentication errors" do
    {private_key, _public_key} = rsa_key_fixture("adapter_defect")

    token =
      sign_fixture(private_key, claims_fixture(System.system_time(:second)), "adapter_defect")

    config = Application.fetch_env!(:hermitscale, JWT)
    Application.put_env(:hermitscale, JWT, Keyword.put(config, :client, String))

    assert_raise UndefinedFunctionError, fn -> JWT.verify(token) end
  end

  test "unrelated advertised signing algorithms do not prevent RSA verification" do
    {private_key, public_key} = rsa_key_fixture("rsa_key")
    other_key = %{"kid" => "ec_key", "kty" => "EC", "alg" => "ES256"}
    Client.put_response(:jwks, {:ok, %{"keys" => [other_key, public_key]}})
    token = sign_fixture(private_key, claims_fixture(System.system_time(:second)), "rsa_key")

    assert {:ok, _claims} = JWT.verify(token)
  end
end
