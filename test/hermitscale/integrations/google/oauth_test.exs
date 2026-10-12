defmodule Hermitscale.Integrations.Google.OAuthTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Integrations.Google.OAuth

  test "rejects local access and refresh-token payloads" do
    assert {:error, :missing_credential_identity} =
             OAuth.fetch_token(%{access_token: "legacy", refresh_token: "legacy"}, [])
  end
end
