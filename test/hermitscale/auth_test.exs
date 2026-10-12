defmodule Hermitscale.AuthTest do
  use ExUnit.Case, async: false

  alias Hermitscale.{Accounts, Auth, Authorization}
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Auth.WorkOS
  alias Hermitscale.AuthTest.{Fixtures, Provider}
  alias Hermitscale.WorkOS.Session
  alias Hermitscale.WorkOSTest.{Client, JWTVerifier}

  setup context do
    previous =
      for module <- [Auth, WorkOS, Session],
          do: {module, Application.get_env(:hermitscale, module)}

    on_exit(fn ->
      for {module, config} <- previous do
        case config do
          nil -> Application.delete_env(:hermitscale, module)
          config -> Application.put_env(:hermitscale, module, config)
        end
      end
    end)

    start_supervised!({Client, %{}})
    start_supervised!({Provider, %{}})

    case context do
      %{provider: provider} ->
        Application.put_env(:hermitscale, Auth, provider: provider)
        Application.put_env(:hermitscale, WorkOS, client: Client)
        Application.put_env(:hermitscale, Session, client: Client, jwt_verifier: JWTVerifier)

        directory =
          start_supervised!({Agent, fn -> Fixtures.directory_fixture(provider) end},
            id: :auth_directory
          )

        Fixtures.configure_provider(provider, directory)
        %{provider: provider, directory: directory}

      _configuration_test ->
        :ok
    end
  end

  for provider <- [WorkOS, Provider] do
    describe "application flows using #{inspect(provider)}" do
      @describetag provider: provider

      test "the same sign-in, workspace, collaboration and execution flows use the configured adapter",
           %{provider: provider} do
        metadata = %{ip_address: "127.0.0.1", user_agent: "adapter-swap-test"}

        assert {:ok, url} =
                 Auth.authorization_url("csrf-state", organization_id: Fixtures.team_id(provider))

        assert url =~ "csrf-state"

        assert {:authorization_url, ["csrf-state", [organization_id: Fixtures.team_id(provider)]]} in Fixtures.calls(
                 provider
               )

        assert {:ok, signed_in} = Auth.sign_in("valid-code", metadata)
        assert_result(signed_in, provider, Fixtures.personal_id(provider))

        assert {exchange_operation(provider), ["valid-code", metadata]} in Fixtures.calls(
                 provider
               )

        assert {:create_membership,
                [Fixtures.user_id(provider), Fixtures.personal_id(provider), "admin"]} in Fixtures.calls(
                 provider
               )

        assert {:ok, authenticated} = Auth.authenticate(signed_in.sealed_session, metadata)
        assert authenticated.current_scope == signed_in.current_scope
        assert {:ok, refreshed} = Auth.refresh_claims(authenticated.sealed_session, metadata)
        assert_result(refreshed, provider, Fixtures.personal_id(provider))
        assert refreshed.session == signed_in.session

        assert {:ok, organizations} = Accounts.list_organizations(refreshed.current_scope)

        assert MapSet.new(organizations, & &1.id) ==
                 MapSet.new([Fixtures.personal_id(provider), Fixtures.team_id(provider)])

        assert {:ok, switched} =
                 Auth.switch_organization(
                   refreshed.sealed_session,
                   Fixtures.team_id(provider),
                   metadata
                 )

        assert_result(switched, provider, Fixtures.team_id(provider))
        assert switched.session == signed_in.session
        assert_switch_metadata(provider, refreshed.sealed_session, metadata)
        scope = switched.current_scope
        assert {:ok, invitation} = Accounts.invite(scope, "new-member@example.test")
        assert invitation.email == "new-member@example.test"
        assert invitation.org_id == Fixtures.team_id(provider)
        assert invitation.role == "runner"
        assert invitation.state == "pending"

        assert {:ok, %{role: "editor"}} =
                 Accounts.assign_role(scope, Fixtures.colleague_membership_id(provider), "editor")

        assert :ok = Accounts.remove_member(scope, Fixtures.colleague_membership_id(provider))

        execution = Scope.execution_context(scope)
        assert {:ok, current_scope} = Authorization.execution_scope(execution)
        assert :ok = Authorization.authorize(current_scope, "workflows:run")

        assert {:ok, %{role: "runner"}} =
                 Accounts.assign_role(scope, Fixtures.owner_membership_id(provider), "runner")

        assert {:ok, downgraded} = Auth.refresh_claims(switched.sealed_session)

        assert {:error, :forbidden} =
                 Accounts.invite(downgraded.current_scope, "blocked@example.test")

        assert :ok = Accounts.remove_member(scope, Fixtures.owner_membership_id(provider))
        assert {:error, :execution_actor_ineligible} = Authorization.execution_scope(execution)

        assert {:ok, logout_url} =
                 Auth.logout(switched.sealed_session, "https://app.example.test/")

        assert is_binary(logout_url)
        assert Auth.socket_topic(switched.session) == "auth_sessions:" <> switched.session.id
        assert_implementation_isolation(provider)
      end

      test "sign-in preserves an existing selected workspace while ensuring a personal workspace",
           %{provider: provider} do
        assert {:ok, result} = Auth.sign_in("team-code")
        assert_result(result, provider, Fixtures.team_id(provider))

        assert {:get_organization_by_external_id, ["personal:" <> Fixtures.user_id(provider)]} in Fixtures.calls(
                 provider
               )

        assert {:ok, organizations} = Accounts.list_organizations(result.current_scope)
        assert Enum.any?(organizations, &(&1.id == Fixtures.personal_id(provider)))
        assert_implementation_isolation(provider)
      end

      test "malformed sessions and unauthorized collaboration do not authenticate or mutate membership",
           %{provider: provider} do
        assert {:error, :invalid_session} = Auth.authenticate(nil)
        assert {:error, :invalid_session} = Auth.authenticate("tampered-session")
        assert {:error, :invalid_session} = Auth.logout("tampered-session")
        assert {:ok, result} = Auth.sign_in("team-code")

        runner_scope =
          put_in(result.current_scope.membership.permissions, ["workflows:run"]).current_scope

        assert {:error, :forbidden} = Accounts.invite(runner_scope, "blocked@example.test")

        assert {:error, :forbidden} =
                 Accounts.assign_role(
                   runner_scope,
                   Fixtures.colleague_membership_id(provider),
                   "admin"
                 )

        assert {:error, :forbidden} =
                 Accounts.remove_member(runner_scope, Fixtures.colleague_membership_id(provider))

        refute Enum.any?(Fixtures.calls(provider), fn {operation, _args} ->
                 operation in [:invite_member, :update_membership, :remove_membership]
               end)

        assert {:error, _reason} =
                 Auth.switch_organization(result.sealed_session, "tenant:inaccessible")

        assert_implementation_isolation(provider)
      end

      test "auth and directory dependency failures retain actionable reasons", %{
        provider: provider,
        directory: directory
      } do
        assert {:ok, result} = Auth.sign_in("team-code")

        for reason <- [:unavailable, :rate_limited, :invalid_response] do
          Fixtures.configure_provider(provider, directory)
          Fixtures.fail(provider, :exchange_code, reason)
          assert {:error, ^reason} = Auth.sign_in("valid-code")
          Fixtures.fail(provider, :refresh_claims, reason)
          assert {:error, ^reason} = Auth.refresh_claims(result.sealed_session)
          Fixtures.fail(provider, :logout, reason)
          assert {:error, ^reason} = Auth.logout(result.sealed_session)
          Fixtures.fail(provider, :get_organization, reason)
          assert {:error, ^reason} = Accounts.list_organizations(result.current_scope)
          Fixtures.fail(provider, :list_memberships, reason)

          assert {:error, ^reason} =
                   Authorization.execution_scope(Scope.execution_context(result.current_scope))
        end

        assert_implementation_isolation(provider)
      end
    end
  end

  describe "provider configuration" do
    test "validates a complete alternate provider and rejects missing callbacks" do
      Application.put_env(:hermitscale, Auth, provider: Provider)
      assert :ok = Auth.validate_provider!()
      Application.put_env(:hermitscale, Auth, provider: __MODULE__)
      assert_raise ArgumentError, ~r/provider|callback/i, fn -> Auth.validate_provider!() end
    end
  end

  defp assert_result(result, provider, org_id) do
    assert is_binary(result.sealed_session)
    assert result.current_scope.user.id == Fixtures.user_id(provider)
    assert result.current_scope.organization.id == org_id
    assert result.current_scope.membership.user_id == result.current_scope.user.id
    assert result.current_scope.membership.org_id == org_id
    assert %DateTime{} = result.session.authenticated_at
    refute Map.has_key?(result, :claims)
    assert :ok = Authorization.authorize(result.current_scope, "members:manage")
  end

  defp assert_implementation_isolation(Provider), do: assert(Client.calls() == [])
  defp assert_implementation_isolation(WorkOS), do: assert(Provider.calls() == [])

  defp exchange_operation(Provider), do: :exchange_code
  defp exchange_operation(WorkOS), do: :authenticate_with_code

  defp assert_switch_metadata(Provider, sealed_session, metadata) do
    assert {:switch_organization, [sealed_session, Fixtures.team_id(Provider), metadata]} in Provider.calls()
  end

  defp assert_switch_metadata(WorkOS, _sealed_session, metadata) do
    assert {:authenticate_with_refresh_token,
            ["refresh_auth_secret", Fixtures.team_id(WorkOS), metadata]} in Client.calls()
  end
end
