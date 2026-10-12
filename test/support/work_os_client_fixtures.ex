defmodule Hermitscale.WorkOS.ClientFixtures do
  @moduledoc false

  def organization_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "org_123",
        "name" => "Test organization",
        "external_id" => "personal:user_123",
        "metadata" => %{}
      },
      overrides
    )
  end

  def invitation_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "invitation_123",
        "email" => "collaborator@example.test",
        "organization_id" => "org_123",
        "role_slug" => "runner",
        "state" => "pending"
      },
      overrides
    )
  end

  def membership_fixture(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "user_id" => "user_123",
        "organization_id" => "org_123",
        "status" => "active",
        "role" => %{"slug" => "admin"}
      },
      overrides
    )
  end

  def credential_fixture(overrides \\ %{}) do
    %{
      "active" => true,
      "credential" =>
        Map.merge(%{"auth_method" => "oauth", "value" => "opaque-secret"}, overrides)
    }
  end

  def provider_fixture do
    %{
      "slug" => "google",
      "connected_accounts" => [
        %{
          "id" => "data_123",
          "organization_id" => "org_123",
          "user_id" => nil,
          "auth_method" => "oauth",
          "state" => "connected",
          "scopes" => ["scope:a"]
        }
      ]
    }
  end
end
