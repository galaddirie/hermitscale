defmodule Hermitscale.CredentialsFixtures do
  @moduledoc """
  Test data for the credential system.
  """

  alias Hermitscale.Credentials
  alias Hermitscale.Credentials.Credential
  alias Hermitscale.Credentials.SecretPayload.{ApiKey, Custom, OAuthToken}
  alias Hermitscale.Repo

  def scope_fixture(attrs \\ %{}) do
    Map.merge(%{org_id: "org_#{System.unique_integer([:positive])}", user_id: nil}, attrs)
  end

  def api_key_credential_fixture(scope \\ scope_fixture(), attrs \\ %{}) do
    {:ok, credential} =
      Credentials.create(
        scope,
        Map.merge(
          %{
            provider: "github",
            name: "test api key",
            payload: %ApiKey{key: "ghp_test_#{System.unique_integer([:positive])}"}
          },
          attrs
        )
      )

    credential
  end

  def oauth_credential_fixture(scope \\ scope_fixture(), attrs \\ %{}) do
    payload =
      attrs[:payload] ||
        %OAuthToken{
          access_token: "access_fresh",
          refresh_token: "refresh_1",
          expires_at: DateTime.add(DateTime.utc_now(:second), 3_600, :second),
          scopes: ["repo"]
        }

    {:ok, credential} =
      Credentials.create(
        scope,
        attrs
        |> Map.delete(:payload)
        |> Enum.into(%{provider: "github", name: "test oauth", payload: payload})
      )

    credential
  end

  def custom_credential_fixture(scope \\ scope_fixture(), attrs \\ %{}) do
    {:ok, credential} =
      Credentials.create(
        scope,
        Map.merge(
          %{
            provider: "internal.custom",
            name: "test custom",
            payload: %Custom{fields: %{"username" => "svc", "password" => "hunter2"}}
          },
          attrs
        )
      )

    credential
  end

  @doc "A bare metadata row with no secret material — for backend-level tests."
  def credential_row_fixture(attrs \\ %{}) do
    defaults = %{
      id: Ecto.UUID.generate(),
      org_id: "org_#{System.unique_integer([:positive])}",
      provider: "github",
      kind: :api_key,
      method: "api_key",
      name: "bare row",
      status: :active,
      backend: "local"
    }

    {:ok, credential} =
      %Credential{}
      |> Credential.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    credential
  end

  def stale_oauth_payload do
    %OAuthToken{
      access_token: "access_stale",
      refresh_token: "refresh_1",
      expires_at: DateTime.add(DateTime.utc_now(:second), -60, :second),
      scopes: ["repo"]
    }
  end
end
