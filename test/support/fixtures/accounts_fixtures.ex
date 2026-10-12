defmodule Hermitscale.AccountsFixtures do
  @moduledoc """
  In-memory WorkOS identities for tests. No local identity records are created.
  """

  alias Hermitscale.Accounts.Scope
  alias Hermitscale.WorkOS.Session

  def unique_user_email, do: "user#{System.unique_integer([:positive])}@example.com"

  def user_fixture(attrs \\ %{}) do
    Enum.into(attrs, %{
      id: "user_#{System.unique_integer([:positive])}",
      email: unique_user_email(),
      first_name: nil,
      last_name: nil
    })
  end

  def organization_fixture(attrs \\ %{}) do
    Enum.into(attrs, %{
      id: "org_#{System.unique_integer([:positive])}",
      name: "Test organization"
    })
  end

  def role_permissions_fixture("admin"),
    do:
      ~w(workflows:run workflows:edit workflows:activate connections:manage members:manage widgets:pipes:manage widgets:users-table:manage)

  def role_permissions_fixture("editor"), do: ~w(workflows:run workflows:edit workflows:activate)
  def role_permissions_fixture("runner"), do: ~w(workflows:run)

  def organization_membership_fixture(user, organization, attrs \\ %{}) do
    Enum.into(attrs, %{
      user_id: user.id,
      org_id: organization.id,
      role: "admin",
      permissions:
        ~w(workflows:run workflows:edit workflows:activate connections:manage members:manage),
      status: :active
    })
  end

  def user_scope_fixture, do: user_scope_fixture(user_fixture())
  def user_scope_fixture(user), do: organization_scope_fixture(user, organization_fixture())
  def organization_scope_fixture, do: user_scope_fixture()
  def organization_scope_fixture(user), do: user_scope_fixture(user)

  def organization_scope_fixture(user, organization) do
    user
    |> Scope.for_user()
    |> Scope.put_organization(
      organization,
      organization_membership_fixture(user, organization)
    )
  end

  def workos_session_fixture(user, opts \\ []) do
    now = Keyword.get(opts, :authenticated_at, DateTime.utc_now(:second))

    claims = %{
      "sub" => user.id,
      "sid" =>
        Keyword.get(opts, :workos_session_id, "session_#{System.unique_integer([:positive])}"),
      "org_id" => Keyword.get(opts, :org_id, "org_#{System.unique_integer([:positive])}"),
      "role" => "member",
      "iat" => DateTime.to_unix(now),
      "auth_time" => DateTime.to_unix(now),
      "exp" => System.system_time(:second) + 3_600
    }

    {:ok, session} =
      Session.create(%{
        "access_token" => Jason.encode!(claims),
        "refresh_token" => "refresh_#{System.unique_integer([:positive])}",
        "user" => %{
          "id" => user.id,
          "email" => user.email,
          "first_name" => user.first_name,
          "last_name" => user.last_name
        }
      })

    session
  end
end
