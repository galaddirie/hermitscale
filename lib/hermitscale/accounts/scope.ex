defmodule Hermitscale.Accounts.Scope do
  @moduledoc """
  Caller identity and tenant authority derived from a verified provider session.

  Identity and organization IDs are opaque provider IDs. These values are held in memory;
  the application does not maintain a second identity or membership database.
  """

  defstruct user: nil, organization: nil, membership: nil

  @type t :: %__MODULE__{user: map() | nil, organization: map() | nil, membership: map() | nil}

  @doc "Creates a scope for a verified identity, or nil for an anonymous caller."
  def for_user(%{id: id} = user) when is_binary(id) and id != "", do: %__MODULE__{user: user}
  def for_user(nil), do: nil

  @doc "Adds the tenant and matching membership supplied by the trusted authentication boundary."
  def put_organization(
        %__MODULE__{user: %{id: user_id}} = scope,
        %{id: org_id} = organization,
        %{user_id: user_id, org_id: org_id} = membership
      )
      when is_binary(org_id) and org_id != "" do
    %{scope | organization: organization, membership: membership}
  end

  @doc "Returns the tenant ID after checking that the scope membership matches."
  def organization_id!(%__MODULE__{
        user: %{id: user_id},
        organization: %{id: org_id},
        membership: %{user_id: user_id, org_id: org_id}
      })
      when is_binary(org_id) and org_id != "",
      do: org_id

  def organization_id!(_scope),
    do: raise(ArgumentError, "scope has no verified organization membership")

  @doc "Derives execution identity exclusively from verified organization membership."
  def execution_context(%__MODULE__{} = scope, permissions \\ ["workflows:run"]) do
    %Hermitscale.Integrations.ExecutionContext{
      organization_id: organization_id!(scope),
      actor_user_id: scope.user.id,
      required_permissions: permissions
    }
  end

  @doc "Asserts that a resource belongs to the caller's active organization."
  def assert_same_org!(%__MODULE__{} = scope, %{org_id: org_id}) do
    true = org_id == organization_id!(scope)
    :ok
  end
end
