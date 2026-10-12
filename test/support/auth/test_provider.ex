defmodule Hermitscale.AuthTest.Provider do
  @moduledoc false

  use Agent
  @behaviour Hermitscale.Auth.Provider

  alias Hermitscale.Accounts.Scope
  alias Hermitscale.AuthTest.Fixtures

  def start_link(initial \\ %{}) do
    Agent.start_link(fn -> Map.merge(Fixtures.directory_fixture(), initial) end, name: __MODULE__)
  end

  def put_response(operation, response) do
    Agent.update(__MODULE__, &put_in(&1, [:responses, operation], response))
  end

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  def reset_responses, do: Agent.update(__MODULE__, &%{&1 | responses: %{}})

  @impl true
  def authorization_url(state, opts) do
    respond(:authorization_url, [state, opts], fn data ->
      {{:ok, "https://identity.example.test/authorize?state=#{state}"}, data}
    end)
  end

  @impl true
  def exchange_code(code, metadata) do
    respond(:exchange_code, [code, metadata], fn data ->
      case code do
        "valid-code" -> issue_session(data, nil)
        "team-code" -> issue_session(data, Fixtures.team_id(__MODULE__))
        _code -> {{:error, :invalid_code}, data}
      end
    end)
  end

  @impl true
  def authenticate(seal, metadata) do
    respond(:authenticate, [seal, metadata], fn data ->
      {fetch_session(data, seal), data}
    end)
  end

  @impl true
  def switch_organization(seal, org_id, metadata) do
    respond(:switch_organization, [seal, org_id, metadata], fn data ->
      with {:ok, result} <- fetch_session(data, seal),
           {:ok, scope} <- scope(data, org_id) do
        rotate_session(data, %{result | current_scope: scope})
      else
        {:error, _reason} = error -> {error, data}
      end
    end)
  end

  @impl true
  def refresh_claims(seal, metadata) do
    respond(:refresh_claims, [seal, metadata], fn data ->
      with {:ok, result} <- fetch_session(data, seal),
           {:ok, scope} <- scope(data, result.current_scope.organization.id) do
        rotate_session(data, %{result | current_scope: scope})
      else
        {:error, _reason} = error -> {error, data}
      end
    end)
  end

  @impl true
  def logout(seal, return_to) do
    respond(:logout, [seal, return_to], fn data ->
      case fetch_session(data, seal) do
        {:ok, result} ->
          sessions =
            Map.reject(data.sessions, fn {_seal, value} ->
              value.session.id == result.session.id
            end)

          {{:ok, "https://identity.example.test/logout"}, %{data | sessions: sessions}}

        {:error, _reason} = error ->
          {error, data}
      end
    end)
  end

  @impl true
  def get_organization_by_external_id(external_id) do
    respond(:get_organization_by_external_id, [external_id], fn data ->
      case Enum.find(Map.values(data.organizations), &(&1.external_id == external_id)) do
        nil -> {{:error, :not_found}, data}
        organization -> {{:ok, organization}, data}
      end
    end)
  end

  @impl true
  def get_organization(id) do
    respond(:get_organization, [id], fn data ->
      {fetch_record(data.organizations, id), data}
    end)
  end

  @impl true
  def create_organization(attrs) do
    respond(:create_organization, [attrs], fn data ->
      organization = Map.put(attrs, :id, Fixtures.personal_id(__MODULE__))
      {{:ok, organization}, put_in(data, [:organizations, organization.id], organization)}
    end)
  end

  @impl true
  def list_memberships(user_id, org_id) do
    respond(:list_memberships, [user_id, org_id], fn data ->
      memberships =
        data.memberships
        |> Map.values()
        |> Enum.filter(&(&1.user_id == user_id and (is_nil(org_id) or &1.org_id == org_id)))

      {{:ok, memberships}, data}
    end)
  end

  @impl true
  def create_membership(user_id, org_id, role) do
    respond(:create_membership, [user_id, org_id, role], fn data ->
      membership = Fixtures.membership_fixture("membership:personal", user_id, org_id, role)
      {{:ok, membership}, put_in(data, [:memberships, membership.id], membership)}
    end)
  end

  @impl true
  def get_membership(id) do
    respond(:get_membership, [id], fn data ->
      {fetch_record(data.memberships, id), data}
    end)
  end

  @impl true
  def update_membership(id, role) do
    respond(:update_membership, [id, role], fn data ->
      case fetch_record(data.memberships, id) do
        {:ok, membership} ->
          membership = %{membership | role: role}
          {{:ok, membership}, put_in(data, [:memberships, id], membership)}

        {:error, _reason} = error ->
          {error, data}
      end
    end)
  end

  @impl true
  def remove_membership(id) do
    respond(:remove_membership, [id], fn data ->
      {:ok, %{data | memberships: Map.delete(data.memberships, id)}}
    end)
  end

  @impl true
  def invite_member(org_id, user_id, email, role) do
    respond(:invite_member, [org_id, user_id, email, role], fn data ->
      {{:ok,
        %{id: "invitation:colleague", org_id: org_id, email: email, role: role, state: "pending"}},
       data}
    end)
  end

  @impl true
  def get_role(slug) do
    respond(:get_role, [slug], fn data ->
      {{:ok, %{slug: slug, permissions: Fixtures.permissions_fixture(slug)}}, data}
    end)
  end

  defp issue_session(data, org_id) do
    with {:ok, scope} <- scope(data, org_id) do
      rotate_session(data, %{
        sealed_session: nil,
        current_scope: scope,
        session: %{id: "auth-session:owner", authenticated_at: data.authenticated_at}
      })
    else
      {:error, _reason} = error -> {error, data}
    end
  end

  defp rotate_session(data, result) do
    seal = "opaque:" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    result = %{result | sealed_session: seal}
    {{:ok, result}, put_in(data, [:sessions, seal], result)}
  end

  defp scope(data, nil), do: {:ok, Scope.for_user(data.user)}

  defp scope(data, org_id) do
    user_id = data.user.id

    case Enum.find(Map.values(data.memberships), &(&1.user_id == user_id and &1.org_id == org_id)) do
      %{status: "active", role: role} = membership ->
        organization = Map.fetch!(data.organizations, org_id)
        membership = Map.put(membership, :permissions, Fixtures.permissions_fixture(role))
        {:ok, Scope.put_organization(Scope.for_user(data.user), organization, membership)}

      _absent_or_inactive ->
        {:error, :forbidden}
    end
  end

  defp fetch_session(data, seal), do: fetch_record(data.sessions, seal, :invalid_session)

  defp fetch_record(records, id, reason \\ :not_found) do
    case Map.fetch(records, id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, reason}
    end
  end

  defp respond(operation, args, callback) do
    Agent.get_and_update(__MODULE__, fn data ->
      {response, updated} =
        case Map.fetch(data.responses, operation) do
          {:ok, response} -> {response, data}
          :error -> callback.(data)
        end

      {response, %{updated | calls: [{operation, args} | updated.calls]}}
    end)
  end
end
