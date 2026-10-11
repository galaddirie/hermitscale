defmodule Hermitscale.Integrations.CredentialRef do
  @moduledoc """
  Opaque, non-secret credential reference safe for workflow persistence.
  """

  @enforce_keys [:id, :organization_id, :provider_id, :provider_slug, :required_scopes]
  defstruct [:id, :organization_id, :provider_id, :provider_slug, :required_scopes]
end
