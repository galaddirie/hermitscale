defmodule Hermitscale.Auth.WorkOSTest do
  use ExUnit.Case, async: false

  alias Hermitscale.Auth.WorkOS
  alias Hermitscale.WorkOS.Session
  alias Hermitscale.WorkOSTest.{Client, JWTVerifier}

  import Hermitscale.WorkOS.ClientFixtures
  import Hermitscale.WorkOS.SessionFixtures

  setup do
    start_supervised!({Client, %{}})
    previous_adapter = Application.get_env(:hermitscale, WorkOS, [])
    previous_session = Application.get_env(:hermitscale, Session, [])
    Application.put_env(:hermitscale, WorkOS, client: Client)
    Application.put_env(:hermitscale, Session, jwt_verifier: JWTVerifier)

    on_exit(fn ->
      Application.put_env(:hermitscale, WorkOS, previous_adapter)
      Application.put_env(:hermitscale, Session, previous_session)
    end)

    :ok
  end

  describe "authentication" do
    test "passes authorization options and exchanges a code into a shared session result" do
      metadata = %{ip_address: "127.0.0.1", user_agent: "test"}
      options = [screen_hint: "sign-up", max_age: 0]
      Client.put_response(:authenticate_with_code, {:ok, authentication_fixture()})

      assert {:ok, _url} = WorkOS.authorization_url("oauth-state", options)
      assert {:ok, result} = WorkOS.exchange_code("oauth-code", metadata)
      assert result.current_scope.user.id == "user_workos"
      assert result.current_scope.organization.id == "org_workos"
      assert result.current_scope.membership.role == "admin"
      assert result.session.id == "session_workos"
      refute Map.has_key?(result, :claims)

      assert [
               {:authorization_url, ["oauth-state", ^options]},
               {:authenticate_with_code, ["oauth-code", ^metadata]}
             ] = Client.calls()

      assert {:ok, authenticated} = WorkOS.authenticate(result.sealed_session, metadata)
      assert authenticated.current_scope == result.current_scope
    end

    test "reports code exchange failures and malformed authentication responses" do
      Client.put_response(:authenticate_with_code, {:error, :rate_limited})
      assert {:error, :rate_limited} = WorkOS.exchange_code("code", %{})
      Client.put_response(:authenticate_with_code, {:ok, %{}})
      assert {:error, :invalid_response} = WorkOS.exchange_code("code", %{})
    end

    test "rejects malformed profile fields and verified authorization claims" do
      authentication = authentication_fixture()

      for field <- ~w(email first_name last_name) do
        malformed = put_in(authentication, ["user", field], %{})
        Client.put_response(:authenticate_with_code, {:ok, malformed})
        assert {:error, :invalid_response} = WorkOS.exchange_code("code", %{})
      end

      for claims <- [%{"role" => %{}}, %{"permissions" => "admin"}, %{"permissions" => [1]}] do
        Client.put_response(:authenticate_with_code, {:ok, authentication_fixture(claims)})
        assert {:error, :invalid_response} = WorkOS.exchange_code("code", %{})
      end

      Client.put_response(
        :authenticate_with_code,
        {:ok, authentication_fixture(%{"role" => nil, "permissions" => nil})}
      )

      assert {:ok, result} = WorkOS.exchange_code("code", %{})
      assert result.current_scope.membership.role == nil
      assert result.current_scope.membership.permissions == []
    end

    test "switches and refreshes verified claims, then revokes the session" do
      {:ok, initial} = Session.create(authentication_fixture())
      metadata = %{user_agent: "test"}

      Client.put_response(
        :authenticate_with_refresh_token,
        {:ok, authentication_fixture(%{"org_id" => "org_team"})}
      )

      assert {:ok, switched} =
               WorkOS.switch_organization(initial.sealed_session, "org_team", metadata)

      assert switched.current_scope.organization.id == "org_team"

      Client.put_response(
        :authenticate_with_refresh_token,
        {:ok, authentication_fixture(%{"org_id" => "org_team", "role" => "runner"})}
      )

      assert {:ok, refreshed} = WorkOS.refresh_claims(switched.sealed_session, metadata)
      assert refreshed.current_scope.membership.role == "runner"
      refute Map.has_key?(refreshed, :claims)
      assert {:ok, url} = WorkOS.logout(refreshed.sealed_session, "https://app.example.com")
      assert url =~ "session_workos"

      assert [
               {:authenticate_with_refresh_token, ["refresh_secret", "org_team", ^metadata]},
               {:authenticate_with_refresh_token, ["refresh_secret", "org_team", ^metadata]},
               {:revoke_session, ["session_workos"]},
               {:logout_url, ["session_workos", "https://app.example.com"]}
             ] = Client.calls()
    end
  end

  describe "organizations" do
    test "normalizes WorkOS fields and converts create attributes at the boundary" do
      raw = organization_fixture()

      normalized = %{
        id: raw["id"],
        name: raw["name"],
        external_id: raw["external_id"],
        metadata: raw["metadata"]
      }

      Client.put_response(:get_organization, {:ok, raw})
      Client.put_response(:get_organization_by_external_id, {:ok, raw})
      Client.put_response(:create_organization, {:ok, raw})
      attributes = Map.take(normalized, [:name, :external_id, :metadata])

      assert {:ok, ^normalized} = WorkOS.get_organization("org_123")
      assert {:ok, ^normalized} = WorkOS.get_organization_by_external_id("personal:user_123")
      assert {:ok, ^normalized} = WorkOS.create_organization(attributes)

      assert {:create_organization,
              [
                %{
                  "name" => attributes.name,
                  "external_id" => attributes.external_id,
                  "metadata" => attributes.metadata
                }
              ]} in Client.calls()
    end

    test "preserves optional values and rejects missing ids or invalid metadata" do
      Client.put_response(:get_organization, {:ok, %{"id" => "org_minimal"}})

      assert {:ok, %{id: "org_minimal", name: nil, external_id: nil, metadata: %{}}} =
               WorkOS.get_organization("org_minimal")

      for raw <- [%{}, %{"id" => ""}, organization_fixture(%{"metadata" => []})] do
        Client.put_response(:get_organization, {:ok, raw})
        assert {:error, :invalid_response} = WorkOS.get_organization("org_123")
      end
    end
  end

  describe "memberships" do
    test "normalizes list and mutation responses to the same membership shape" do
      raw = membership_fixture("om_123")

      expected = %{
        id: "om_123",
        user_id: "user_123",
        org_id: "org_123",
        status: "active",
        role: "admin"
      }

      Client.put_response(:list_memberships, {:ok, %{"data" => [raw]}})
      Client.put_response(:get_membership, {:ok, raw})
      Client.put_response(:create_membership, {:ok, raw})
      Client.put_response(:update_membership, {:ok, raw})

      assert {:ok, [^expected]} = WorkOS.list_memberships("user_123", "org_123")
      assert {:ok, ^expected} = WorkOS.get_membership("om_123")
      assert {:ok, ^expected} = WorkOS.create_membership("user_123", "org_123", "admin")
      assert {:ok, ^expected} = WorkOS.update_membership("om_123", "admin")
      assert :ok = WorkOS.remove_membership("om_123")
    end

    test "handles absent role and rejects malformed roles and list items" do
      Client.put_response(:get_membership, {:ok, membership_fixture("om_123", %{"role" => nil})})
      assert {:ok, %{role: nil}} = WorkOS.get_membership("om_123")

      for raw <- [
            %{},
            membership_fixture("om_123", %{"role" => %{}}),
            membership_fixture("om_123", %{"status" => nil})
          ] do
        Client.put_response(:get_membership, {:ok, raw})
        assert {:error, :invalid_response} = WorkOS.get_membership("om_123")
        Client.put_response(:list_memberships, {:ok, %{"data" => [raw]}})
        assert {:error, :invalid_response} = WorkOS.list_memberships("user_123", nil)
      end

      Client.put_response(:list_memberships, {:ok, %{"data" => %{}}})
      assert {:error, :invalid_response} = WorkOS.list_memberships("user_123", nil)
    end
  end

  describe "invitations and roles" do
    test "maps invitations and permissions without exposing WorkOS data keys" do
      raw = invitation_fixture()
      Client.put_response(:invite_member, {:ok, raw})

      expected = %{
        id: raw["id"],
        email: raw["email"],
        org_id: raw["organization_id"],
        role: raw["role_slug"],
        state: raw["state"]
      }

      assert {:ok, ^expected} =
               WorkOS.invite_member("org_123", "user_123", raw["email"], "runner")

      Client.put_response(
        :get_role,
        {:ok, %{"slug" => "runner", "permissions" => ["workflows:run"]}}
      )

      assert {:ok, %{slug: "runner", permissions: ["workflows:run"]}} = WorkOS.get_role("runner")
      Client.put_response(:get_role, {:ok, %{"slug" => "runner"}})
      assert {:ok, %{slug: "runner", permissions: []}} = WorkOS.get_role("runner")
    end

    test "rejects malformed invitations and permission lists" do
      Client.put_response(:invite_member, {:ok, %{}})

      assert {:error, :invalid_response} =
               WorkOS.invite_member("org_123", "user_123", "invitee@example.com", "runner")

      for raw <- [%{}, %{"slug" => "runner", "permissions" => ["workflows:run", 1]}] do
        Client.put_response(:get_role, {:ok, raw})
        assert {:error, :invalid_response} = WorkOS.get_role("runner")
      end
    end
  end

  test "preserves actionable dependency errors across directory operations" do
    operations = [
      {:get_organization, ["org_123"]},
      {:get_organization_by_external_id, ["personal:user_123"]},
      {:create_organization,
       [%{name: "Workspace", external_id: "personal:user_123", metadata: %{}}]},
      {:list_memberships, ["user_123", "org_123"]},
      {:get_membership, ["om_123"]},
      {:create_membership, ["user_123", "org_123", "admin"]},
      {:update_membership, ["om_123", "runner"]},
      {:remove_membership, ["om_123"]},
      {:invite_member, ["org_123", "user_123", "invitee@example.com", "runner"]},
      {:get_role, ["runner"]}
    ]

    for {operation, arguments} <- operations do
      Client.put_response(operation, {:error, :unavailable})
      assert {:error, :unavailable} = apply(WorkOS, operation, arguments)
    end
  end
end
