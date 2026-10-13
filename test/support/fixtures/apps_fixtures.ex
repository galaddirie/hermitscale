defmodule Hermitscale.AppsFixtures do
  @moduledoc false
  alias Hermitscale.{Apps, AccountsFixtures}

  def app_scope_fixture do
    scope = AccountsFixtures.organization_scope_fixture()

    %{
      scope
      | membership: %{
          scope.membership
          | permissions: AccountsFixtures.role_permissions_fixture("admin")
        }
    }
  end

  def app_fixture(scope, attrs \\ %{}) do
    {:ok, app} =
      Apps.create_app(
        scope,
        Map.merge(
          %{
            name: "Example app",
            slug: "example-app-#{System.unique_integer([:positive])}"
          },
          attrs
        )
      )

    app
  end

  def app_build_fixture(scope, app) do
    {:ok, session} = Apps.start_build(scope, app.id, %{})
    session
  end

  def service_attrs_fixture(attrs \\ %{}) do
    Map.merge(%{start_command: "python3 -m http.server 8080", port: 8080}, attrs)
  end

  def colleague_app_scope_fixture(scope) do
    colleague = AccountsFixtures.user_fixture(%{id: "colleague"})
    other = AccountsFixtures.organization_scope_fixture(colleague, scope.organization)

    %{
      other
      | membership: %{
          other.membership
          | permissions: AccountsFixtures.role_permissions_fixture("admin")
        }
    }
  end
end
