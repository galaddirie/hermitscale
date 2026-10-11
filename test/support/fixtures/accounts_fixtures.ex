defmodule Hermitscale.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Hermitscale.Accounts` context.
  """

  import Ecto.Query

  alias Hermitscale.Accounts
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Integrations.ConnectedAccount
  alias Hermitscale.WorkOS.Session

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  def user_fixture(attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)

    token =
      extract_user_token(fn url ->
        Accounts.deliver_login_instructions(user, url)
      end)

    {:ok, {user, _expired_tokens}} =
      Accounts.login_user_by_magic_link(token)

    {:ok, user} =
      user
      |> Accounts.User.workos_changeset(%{
        workos_user_id:
          Map.get(attrs, :workos_user_id, "user_#{System.unique_integer([:positive])}"),
        email: user.email,
        email_verified: true,
        workos_updated_at: DateTime.utc_now(:microsecond),
        confirmed_at: user.confirmed_at
      })
      |> Hermitscale.Repo.update()

    user
  end

  def workos_session_fixture(user, opts \\ []) do
    user = ensure_workos_user(user)
    organization = session_organization(user, opts[:org_id])
    organization = ensure_workos_organization(organization)
    now = Keyword.get(opts, :authenticated_at, DateTime.utc_now(:second))

    session_id =
      Keyword.get(opts, :workos_session_id, "session_#{System.unique_integer([:positive])}")

    claims =
      %{
        "sub" => user.workos_user_id,
        "sid" => session_id,
        "iat" => DateTime.to_unix(now),
        "auth_time" => DateTime.to_unix(now),
        "exp" => DateTime.utc_now(:second) |> DateTime.add(3_600, :second) |> DateTime.to_unix()
      }
      |> maybe_put_org_claim(organization)

    verified = %{
      access_token: Jason.encode!(claims),
      refresh_token: "refresh_#{System.unique_integer([:positive])}",
      claims: claims
    }

    {:ok, session} = Session.create_verified(user, verified)
    session
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    {org, membership} = Accounts.resolve_organization(user, nil)

    user
    |> Scope.for_user()
    |> Scope.put_organization(org, membership)
  end

  def organization_scope_fixture, do: user_scope_fixture()
  def organization_scope_fixture(user), do: user_scope_fixture(user)

  def organization_scope_fixture(user, org) do
    membership =
      Accounts.get_user_membership(user, org.id) ||
        organization_membership_fixture(user, org)

    user
    |> Scope.for_user()
    |> Scope.put_organization(org, membership)
  end

  def organization_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        id: Ecto.UUID.generate(),
        name: "org-#{System.unique_integer([:positive])}",
        personal: false
      })

    {:ok, org} =
      %Accounts.Organization{}
      |> Accounts.Organization.changeset(attrs)
      |> Hermitscale.Repo.insert()

    org
  end

  def organization_membership_fixture(user, org, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{org_id: org.id, user_id: user.id, role: :member})

    {:ok, membership} =
      %Accounts.OrganizationMembership{}
      |> Accounts.OrganizationMembership.changeset(attrs)
      |> Hermitscale.Repo.insert()

    membership
  end

  def connected_account_fixture(user, organization, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        owner_user_id: user.id,
        org_id: organization.id,
        provider_id: "google.oauth",
        provider_slug: "google",
        backend: :workos_pipes,
        workos_connected_account_id: "connected_account_#{System.unique_integer([:positive])}",
        workos_organization_id: organization.workos_organization_id,
        state: :connected,
        sharing_mode: if(organization.personal, do: :private, else: :organization),
        granted_scopes: [
          "https://www.googleapis.com/auth/spreadsheets.readonly",
          "https://www.googleapis.com/auth/spreadsheets"
        ],
        workos_updated_at: DateTime.utc_now(:microsecond)
      })

    {:ok, account} =
      %ConnectedAccount{}
      |> ConnectedAccount.create_changeset(attrs)
      |> Hermitscale.Repo.insert()

    account
  end

  defp ensure_workos_user(%Accounts.User{workos_user_id: workos_user_id} = user)
       when is_binary(workos_user_id),
       do: user

  defp ensure_workos_user(user) do
    {:ok, user} =
      user
      |> Accounts.User.workos_changeset(%{
        workos_user_id: "user_#{System.unique_integer([:positive])}",
        email: user.email,
        email_verified: true,
        workos_updated_at: DateTime.utc_now(:microsecond),
        confirmed_at: user.confirmed_at || DateTime.utc_now(:second)
      })
      |> Hermitscale.Repo.update()

    user
  end

  defp session_organization(user, nil) do
    {organization, _membership} = Accounts.resolve_organization(user, nil)
    organization
  end

  defp session_organization(_user, org_id),
    do: Hermitscale.Repo.get!(Accounts.Organization, org_id)

  defp ensure_workos_organization(%Accounts.Organization{personal: true} = organization),
    do: organization

  defp ensure_workos_organization(
         %Accounts.Organization{workos_organization_id: workos_id} = organization
       )
       when is_binary(workos_id),
       do: organization

  defp ensure_workos_organization(organization) do
    {:ok, organization} =
      organization
      |> Accounts.Organization.changeset(%{
        workos_organization_id: "org_#{System.unique_integer([:positive])}",
        provisioning_state: :ready,
        workos_updated_at: DateTime.utc_now(:microsecond)
      })
      |> Hermitscale.Repo.update()

    organization
  end

  defp maybe_put_org_claim(claims, %Accounts.Organization{personal: true}), do: claims

  defp maybe_put_org_claim(claims, %Accounts.Organization{
         workos_organization_id: workos_organization_id
       }) do
    Map.put(claims, "org_id", workos_organization_id)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Hermitscale.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    Hermitscale.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Hermitscale.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
