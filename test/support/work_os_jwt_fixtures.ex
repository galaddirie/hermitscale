defmodule Hermitscale.WorkOS.JWTFixtures do
  @moduledoc false

  def rsa_key_fixture(kid) do
    private_key = JOSE.JWK.generate_key({:rsa, 1_024})
    {_metadata, public_map} = private_key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    {private_key, Map.put(public_map, "kid", kid)}
  end

  def sign_fixture(private_key, claims, kid) do
    private_key
    |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => kid}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  def claims_fixture(now) do
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
