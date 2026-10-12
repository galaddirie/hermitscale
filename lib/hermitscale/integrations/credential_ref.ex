defmodule Hermitscale.Integrations.CredentialRef do
  @moduledoc """
  Non-secret WorkOS Pipes identity for an immediate provider request.

  User and organization IDs come from trusted workflow ownership metadata,
  never from the graph's credential binding.
  """

  @enforce_keys [:user_id, :organization_id, :provider_id, :provider_slug, :required_scopes]
  defstruct [:user_id, :organization_id, :provider_id, :provider_slug, :required_scopes]
end
