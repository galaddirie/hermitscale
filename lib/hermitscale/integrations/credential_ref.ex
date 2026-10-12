defmodule Hermitscale.Integrations.CredentialRef do
  @moduledoc "Validated account selection and trusted execution identity; contains no secret."
  @enforce_keys [:execution_context, :provider_id, :account_id, :required_scopes]
  defstruct [:execution_context, :provider_id, :account_id, :required_scopes]
end
