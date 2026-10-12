defmodule Hermitscale.Auth.Provider do
  @moduledoc """
  Authentication and identity authority supplied by a configured provider.

  IDs and sealed sessions are opaque, nonempty strings. Providers verify tokens
  and normalize their native data before returning it. Application code never
  consumes vendor claims or response envelopes. Authentication results must
  contain a verified scope and session; refresh and workspace switching must
  preserve the user, session identity, and original browser lifetime.

  Membership status is a string, with `"active"` granting eligibility. Missing
  roles grant no permissions. Directory operations return normalized atom-key
  maps, and list operations return lists without pagination envelopes.

  Expected failures return `{:error, reason}`. Dependency failures such as
  `:unavailable`, `:rate_limited`, and `:invalid_response` remain distinguishable
  from invalid credentials, invalid sessions, and ineligible members.
  """

  alias Hermitscale.Accounts.Scope

  @type id :: String.t()
  @type metadata :: %{optional(:ip_address) => String.t(), optional(:user_agent) => String.t()}
  @type result(value) :: {:ok, value} | {:error, atom()}
  @type user :: %{
          required(:id) => id(),
          optional(:email) => String.t() | nil,
          optional(:first_name) => String.t() | nil,
          optional(:last_name) => String.t() | nil
        }
  @type organization :: %{
          required(:id) => id(),
          optional(:name) => String.t() | nil,
          optional(:external_id) => String.t() | nil,
          optional(:metadata) => map()
        }
  @type membership :: %{
          required(:id) => id(),
          required(:user_id) => id(),
          required(:org_id) => id(),
          required(:status) => String.t(),
          required(:role) => String.t() | nil
        }
  @type role :: %{slug: String.t(), permissions: [String.t()]}
  @type invitation :: %{
          id: id(),
          email: String.t(),
          org_id: id(),
          role: String.t() | nil,
          state: String.t() | nil
        }
  @type authentication :: %{
          sealed_session: String.t(),
          current_scope: Scope.t(),
          session: %{id: id(), authenticated_at: DateTime.t()}
        }

  @callback authorization_url(String.t(), keyword()) :: result(String.t())
  @callback exchange_code(String.t(), metadata()) :: result(authentication())
  @callback authenticate(String.t(), metadata()) :: result(authentication())
  @callback switch_organization(String.t(), id(), metadata()) :: result(authentication())
  @callback refresh_claims(String.t(), metadata()) :: result(authentication())
  @callback logout(String.t(), String.t() | nil) :: result(String.t())

  @callback get_organization_by_external_id(String.t()) :: result(organization())
  @callback get_organization(id()) :: result(organization())
  @callback create_organization(%{external_id: String.t(), name: String.t(), metadata: map()}) ::
              result(organization())
  @callback list_memberships(id(), id() | nil) :: result([membership()])
  @callback get_membership(id()) :: result(membership())
  @callback create_membership(id(), id(), String.t()) :: result(membership())
  @callback update_membership(id(), String.t()) :: result(membership())
  @callback remove_membership(id()) :: :ok | {:error, atom()}
  @callback invite_member(id(), id(), String.t(), String.t()) :: result(invitation())
  @callback get_role(String.t()) :: result(role())
end
