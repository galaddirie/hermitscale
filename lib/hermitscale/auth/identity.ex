defmodule Hermitscale.Auth.Identity do
  @moduledoc """
  A normalized, provider-verified identity — the neutral exchange type
  between an identity provider's callback and local user provisioning
  (`Hermitscale.Auth.upsert_user_from_identity/1`).
  """

  @enforce_keys [:provider, :provider_user_id, :email]
  defstruct [
    :provider,
    :provider_user_id,
    :email,
    :email_verified,
    :first_name,
    :last_name,
    # Upstream organization id (e.g. WorkOS organization_id), nil for
    # users without one.
    :org_external_ref,
    # Per-login state the provider needs back at logout (e.g. the WorkOS
    # session id). Carried in the Plug session, never persisted.
    :session_metadata,
    # Full raw profile map, persisted on the user_identities row.
    :raw
  ]

  @type t :: %__MODULE__{
          provider: String.t(),
          provider_user_id: String.t(),
          email: String.t(),
          email_verified: boolean() | nil,
          first_name: String.t() | nil,
          last_name: String.t() | nil,
          org_external_ref: String.t() | nil,
          session_metadata: map() | nil,
          raw: map() | nil
        }
end
