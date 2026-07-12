defmodule Hermitscale.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `Hermitscale.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use as authorization, or to
  ensure specific code paths can only be access for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias Hermitscale.Accounts.{User, Organization, OrganizationMembership}

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
  scope. See `HermitscaleWeb.UserAuth.assign_org_to_scope/2` for how the
  active organization is resolved.
  """
  def put_organization(
        %__MODULE__{} = scope,
        %Organization{} = org,
        %OrganizationMembership{} = membership
      ) do
    %{scope | organization: org, membership: membership}
  end

  @doc """
  Bridges to the map-shaped scope `Hermitscale.Credentials` expects.
  """
  def credentials_scope(%__MODULE__{organization: %Organization{id: org_id}} = scope) do
    %{org_id: org_id, user_id: scope.user && to_string(scope.user.id)}
  end
end
