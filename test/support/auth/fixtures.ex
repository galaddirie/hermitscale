defmodule Hermitscale.AuthTest.Fixtures do
  @moduledoc false

  alias Hermitscale.Auth.WorkOS
  alias Hermitscale.AuthTest.Provider
  alias Hermitscale.WorkOSTest.Client

  def user_id(WorkOS), do: "user_auth_owner"
  def user_id(Provider), do: "person:owner"
  def team_id(WorkOS), do: "org_auth_team"
  def team_id(Provider), do: "tenant:team"
  def personal_id(WorkOS), do: "org_auth_personal"
  def personal_id(Provider), do: "tenant:personal"
  def owner_membership_id(WorkOS), do: "om_auth_owner"
  def owner_membership_id(Provider), do: "membership:owner"
  def colleague_membership_id(WorkOS), do: "om_auth_colleague"
  def colleague_membership_id(Provider), do: "membership:colleague"

  def permissions_fixture(role), do: Hermitscale.AccountsFixtures.role_permissions_fixture(role)

  def membership_fixture(id, user_id, org_id, role) do
    %{id: id, user_id: user_id, org_id: org_id, status: "active", role: role}
  end

  def directory_fixture(provider \\ Provider) do
    team_id = team_id(provider)
    owner_id = owner_membership_id(provider)
    colleague_id = colleague_membership_id(provider)

    %{
      authenticated_at: DateTime.add(DateTime.utc_now(:second), -300, :second),
      user: %{
        id: user_id(provider),
        email: "owner@example.test",
        first_name: "Ada",
        last_name: nil
      },
      organizations: %{team_id => %{id: team_id, name: "Team", external_id: nil, metadata: %{}}},
      memberships: %{
        owner_id => membership_fixture(owner_id, user_id(provider), team_id, "admin"),
        colleague_id => membership_fixture(colleague_id, "colleague", team_id, "runner")
      },
      sessions: %{},
      responses: %{},
      calls: []
    }
  end

  def configure_provider(Provider, _directory), do: Provider.reset_responses()

  def configure_provider(WorkOS, directory) do
    Client.put_response(:authenticate_with_code, fn code, _metadata ->
      case code do
        "valid-code" -> {:ok, authentication_fixture(directory, nil)}
        "team-code" -> {:ok, authentication_fixture(directory, team_id(WorkOS))}
        _other -> {:error, :invalid_code}
      end
    end)

    Client.put_response(:authenticate_with_refresh_token, fn _token, org_id, _metadata ->
      case active_membership(directory, org_id) do
        nil -> {:error, :invalid_grant}
        _membership -> {:ok, authentication_fixture(directory, org_id)}
      end
    end)

    Client.put_response(:get_organization_by_external_id, fn external_id ->
      case Agent.get(
             directory,
             &Enum.find(Map.values(&1.organizations), fn org -> org.external_id == external_id end)
           ) do
        nil -> {:error, :not_found}
        organization -> {:ok, raw_organization(organization)}
      end
    end)

    Client.put_response(:create_organization, fn attrs ->
      organization = %{
        id: personal_id(WorkOS),
        name: attrs["name"],
        external_id: attrs["external_id"],
        metadata: attrs["metadata"]
      }

      Agent.update(directory, &put_in(&1, [:organizations, organization.id], organization))
      {:ok, raw_organization(organization)}
    end)

    Client.put_response(:get_organization, fn id ->
      {:ok, directory |> Agent.get(&Map.fetch!(&1.organizations, id)) |> raw_organization()}
    end)

    Client.put_response(:list_memberships, fn user_id, org_id ->
      memberships =
        Agent.get(directory, fn data ->
          data.memberships
          |> Map.values()
          |> Enum.filter(&(&1.user_id == user_id and (is_nil(org_id) or &1.org_id == org_id)))
          |> Enum.map(&raw_membership/1)
        end)

      {:ok, %{"data" => memberships}}
    end)

    Client.put_response(:create_membership, fn user_id, org_id, role ->
      membership = membership_fixture("om_auth_personal", user_id, org_id, role)
      Agent.update(directory, &put_in(&1, [:memberships, membership.id], membership))
      {:ok, raw_membership(membership)}
    end)

    Client.put_response(:get_membership, fn id ->
      {:ok, directory |> Agent.get(&Map.fetch!(&1.memberships, id)) |> raw_membership()}
    end)

    Client.put_response(:update_membership, fn id, role ->
      membership =
        Agent.get_and_update(directory, fn data ->
          membership = %{Map.fetch!(data.memberships, id) | role: role}
          {membership, put_in(data, [:memberships, id], membership)}
        end)

      {:ok, raw_membership(membership)}
    end)

    Client.put_response(:remove_membership, fn id ->
      Agent.update(directory, &%{&1 | memberships: Map.delete(&1.memberships, id)})
      {:ok, %{}}
    end)

    Client.put_response(:invite_member, fn org_id, _user_id, email, role ->
      {:ok,
       %{
         "id" => "invitation_auth",
         "organization_id" => org_id,
         "email" => email,
         "role_slug" => role,
         "state" => "pending"
       }}
    end)

    :ok
  end

  def fail(Provider, operation, reason), do: Provider.put_response(operation, {:error, reason})

  def fail(WorkOS, :exchange_code, reason),
    do: Client.put_response(:authenticate_with_code, {:error, reason})

  def fail(WorkOS, :refresh_claims, reason),
    do: Client.put_response(:authenticate_with_refresh_token, {:error, reason})

  def fail(WorkOS, :logout, reason), do: Client.put_response(:revoke_session, {:error, reason})
  def fail(WorkOS, operation, reason), do: Client.put_response(operation, {:error, reason})

  def calls(Provider), do: Provider.calls()
  def calls(WorkOS), do: Client.calls()

  defp authentication_fixture(directory, org_id) do
    data = Agent.get(directory, & &1)
    user = data.user
    now = System.system_time(:second)

    role =
      case active_membership(directory, org_id) do
        nil -> nil
        membership -> membership.role
      end

    claims = %{
      "sub" => user.id,
      "sid" => "session_auth_owner",
      "org_id" => org_id,
      "role" => role,
      "permissions" => if(is_nil(role), do: [], else: permissions_fixture(role)),
      "iat" => now,
      "auth_time" => DateTime.to_unix(data.authenticated_at),
      "exp" => now + 3_600
    }

    %{
      "access_token" => Jason.encode!(claims),
      "refresh_token" => "refresh_auth_secret",
      "user" => %{"id" => user.id, "email" => user.email, "first_name" => user.first_name}
    }
  end

  defp active_membership(directory, org_id) do
    Agent.get(directory, fn data ->
      Enum.find(
        Map.values(data.memberships),
        &(&1.user_id == data.user.id and &1.org_id == org_id and &1.status == "active")
      )
    end)
  end

  defp raw_organization(organization) do
    %{
      "id" => organization.id,
      "name" => organization.name,
      "external_id" => organization.external_id,
      "metadata" => organization.metadata
    }
  end

  defp raw_membership(membership) do
    %{
      "id" => membership.id,
      "user_id" => membership.user_id,
      "organization_id" => membership.org_id,
      "status" => membership.status,
      "role" => %{"slug" => membership.role}
    }
  end
end
