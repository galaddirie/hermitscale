defmodule Hermitscale.Credentials.SecretPayloadTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Credentials.{AccessToken, Resolved, SecretPayload}
  alias Hermitscale.Credentials.SecretPayload.{ApiKey, Custom, OAuthToken}

  describe "serialization" do
    test "every payload kind round-trips through to_map/from_map" do
      expires_at = DateTime.utc_now(:second)

      payloads = [
        %ApiKey{key: "sk_123"},
        %OAuthToken{
          access_token: "a",
          refresh_token: "r",
          expires_at: expires_at,
          scopes: ["repo"]
        },
        %OAuthToken{access_token: "a", refresh_token: nil, expires_at: nil},
        %Custom{fields: %{"user" => "u", "pass" => "p"}}
      ]

      for payload <- payloads do
        map = SecretPayload.to_map(payload)

        assert {:ok, ^payload} =
                 map |> Jason.encode!() |> Jason.decode!() |> SecretPayload.from_map()
      end
    end

    test "garbage maps are rejected" do
      assert {:error, :invalid_secret_payload} = SecretPayload.from_map(%{"kind" => "unknown"})
      assert {:error, :invalid_secret_payload} = SecretPayload.from_map(%{})
    end
  end

  describe "redaction" do
    test "no secret value survives inspect/1" do
      secret = "super_secret_value_xyz"

      redacted = [
        %ApiKey{key: secret},
        %OAuthToken{access_token: secret, refresh_token: secret},
        %Custom{fields: %{"password" => secret}},
        %AccessToken{access_token: secret},
        %Resolved{
          credential_id: "cred_1",
          provider: "github",
          method: "api_key",
          auth: {:bearer, secret}
        }
      ]

      for struct <- redacted do
        refute inspect(struct) =~ secret
        refute inspect([struct], limit: :infinity) =~ secret
      end
    end
  end
end
