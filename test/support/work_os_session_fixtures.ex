defmodule Hermitscale.WorkOS.SessionFixtures do
  @moduledoc false

  def authentication_fixture(overrides \\ %{}) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "sub" => "user_workos",
          "sid" => "session_workos",
          "org_id" => "org_workos",
          "role" => "admin",
          "permissions" => ["workflow:write"],
          "iat" => now,
          "auth_time" => now - 300,
          "exp" => now + 3600
        },
        overrides
      )

    %{
      "access_token" => Jason.encode!(claims),
      "refresh_token" => "refresh_secret",
      "user" => %{"id" => "user_workos", "email" => "user@example.com"}
    }
  end

  def expired_browser_session_fixture do
    {:ok, authentication} = Hermitscale.WorkOS.Session.create(authentication_fixture())

    {:ok, payload} =
      Phoenix.Token.decrypt(
        HermitscaleWeb.Endpoint,
        "workos-browser-session-v1",
        authentication.sealed_session
      )

    payload = Map.put(payload, :started_at, System.system_time(:second) - 120)
    Phoenix.Token.encrypt(HermitscaleWeb.Endpoint, "workos-browser-session-v1", payload)
  end
end
