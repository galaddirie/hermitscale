defmodule Hermitscale.WorkOS.JWTTest do
  use ExUnit.Case, async: false

  alias Hermitscale.WorkOS.JWT
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
    {private_key, public_key} = rsa_key("kid_one")
    Client.put_response(:jwks, {:ok, %{"keys" => [public_key]}})

    now = System.system_time(:second)
    token = sign(private_key, valid_claims(now), "kid_one")

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
    {private_key, public_key} = rsa_key("kid_claims")
    Client.put_response(:jwks, {:ok, %{"keys" => [public_key]}})
    now = System.system_time(:second)

    for claims <- [
          Map.put(valid_claims(now), "iss", "https://attacker.example"),
          Map.put(valid_claims(now), "client_id", "another_client"),
          Map.put(valid_claims(now), "iat", now + 61),
          Map.put(valid_claims(now), "exp", now)
        ] do
      assert {:error, _reason} = JWT.verify(sign(private_key, claims, "kid_claims"), now: now)
    end
  end

  test "derives the default WorkOS issuer from the configured client application" do
    {private_key, public_key} = rsa_key("kid_application_issuer")
    Client.put_response(:jwks, {:ok, %{"keys" => [public_key]}})

    config =
      :hermitscale
      |> Application.fetch_env!(JWT)
      |> Keyword.delete(:issuer)

    Application.put_env(:hermitscale, JWT, config)

    now = System.system_time(:second)

    claims =
      Map.put(
        valid_claims(now),
        "iss",
        "https://api.workos.com/user_management/client_123"
      )

    assert {:ok, _claims} =
             private_key
             |> sign(claims, "kid_application_issuer")
             |> JWT.verify(now: now)

    other_client_claims =
      Map.put(
        claims,
        "iss",
        "https://api.workos.com/user_management/client_other"
      )

    assert {:error, :invalid_issuer} =
             private_key
             |> sign(other_client_claims, "kid_application_issuer")
             |> JWT.verify(now: now)
  end

  test "refreshes JWKS once for an unknown kid and accepts key rollover" do
    {first_private, first_public} = rsa_key("kid_old")
    {second_private, second_public} = rsa_key("kid_new")
    now = System.system_time(:second)

    Client.put_response(:jwks, {:ok, %{"keys" => [first_public]}})

    assert {:ok, _claims} =
             first_private
             |> sign(valid_claims(now), "kid_old")
             |> JWT.verify(now: now)

    Client.put_response(:jwks, {:ok, %{"keys" => [first_public, second_public]}})

    assert {:ok, _claims} =
             second_private
             |> sign(valid_claims(now), "kid_new")
             |> JWT.verify(now: now)

    assert [
             {:jwks, []},
             {:jwks, []}
           ] = Client.calls()
  end

  test "fails closed when a signing key remains unknown" do
    {_private_key, public_key} = rsa_key("known")
    {unknown_private, _unknown_public} = rsa_key("unknown")
    Client.put_response(:jwks, {:ok, %{"keys" => [public_key]}})
    now = System.system_time(:second)

    assert {:error, :unknown_signing_key} =
             unknown_private
             |> sign(valid_claims(now), "unknown")
             |> JWT.verify(now: now)
  end

  defp rsa_key(kid) do
    private_key = JOSE.JWK.generate_key({:rsa, 1_024})
    {_metadata, public_map} = private_key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    {private_key, Map.put(public_map, "kid", kid)}
  end

  defp sign(private_key, claims, kid) do
    private_key
    |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => kid}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp valid_claims(now) do
    %{
      "iss" => "https://api.workos.test/",
      "client_id" => "client_123",
      "sub" => "user_123",
      "sid" => "session_123",
      "iat" => now,
      "auth_time" => now - 30,
      "exp" => now + 300
    }
  end
end
