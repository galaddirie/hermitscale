defmodule Hermitscale.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The scope identifies both the authenticated user and their active
  organization membership. Contexts authorize tenant-owned resources with the
  organization id; the user remains available for actor-specific audit data.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  The membership is retained as the extension point for role-aware policies.
  """

  alias Hermitscale.Accounts.{Organization, OrganizationMembership, User}

  defstruct user: nil, organization: nil, membership: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  Puts the active organization (and the user's membership in it) on the
  scope. See `HermitscaleWeb.UserAuth.fetch_current_scope_for_user/2` for
  how the active organization is resolved.
  """
  def put_organization(
        %__MODULE__{user: %User{id: user_id}} = scope,
        %Organization{id: org_id} = org,
        %OrganizationMembership{user_id: user_id, org_id: org_id} = membership
      ) do
    %{scope | organization: org, membership: membership}
  end

  @doc "Returns the active organization id after validating the scope membership."
  def organization_id!(%__MODULE__{
        user: %User{id: user_id},
        organization: %Organization{id: org_id},
        membership: %OrganizationMembership{user_id: user_id, org_id: org_id}
      })
      when is_binary(org_id),
      do: org_id

  @doc """
  Asserts that the resource belongs to the scope's active organization.

  This is a tenancy check, not a role check — any member of the owning
  organization passes. Role-aware policies belong on `membership.role`.
  """
  def assert_same_org!(%__MODULE__{} = scope, %{org_id: org_id}) do
    true = org_id == organization_id!(scope)
    :ok
  end
end
