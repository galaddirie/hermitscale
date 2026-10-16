defmodule Hermitscale.Auth do
  @moduledoc """
  Shared authentication interface and sign-in orchestration.

  Select an implementation of `Hermitscale.Auth.Provider` using:

      config :hermitscale, Hermitscale.Auth, provider: Hermitscale.Auth.WorkOS

  Provider selection is read at runtime. Sessions are opaque to callers; users,
  organizations, and memberships use the provider's IDs without format assumptions.
  """

  alias Hermitscale.Accounts
  alias Hermitscale.Auth.Provider

  @doc "Returns the configured authentication provider."
  def provider do
    :hermitscale
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:provider)
  end

  @doc "Validates the configured provider before the application starts."
  def validate_provider! do
    module = provider()

    with {:module, ^module} <- Code.ensure_loaded(module),
         [] <-
           Enum.reject(Provider.behaviour_info(:callbacks), fn {name, arity} ->
             function_exported?(module, name, arity)
           end) do
      :ok
    else
      {:error, reason} ->
        raise ArgumentError, "cannot load auth provider #{inspect(module)}: #{inspect(reason)}"

      missing when is_list(missing) ->
        raise ArgumentError,
              "auth provider #{inspect(module)} is missing callbacks: #{inspect(missing)}"
    end
  end

  @doc "Builds the provider's sign-in URL for a caller-generated OAuth state."
  def authorization_url(state, opts \\ []), do: provider().authorization_url(state, opts)

  @doc "Exchanges a code and establishes the user's workspace through the shared flow."
  def sign_in(code, metadata \\ %{}) do
    with {:ok, authentication} <- provider().exchange_code(code, metadata) do
      establish(authentication, metadata)
    end
  end

  @doc "Exchanges a code for a verified identity without selecting a workspace."
  def exchange_code(code, metadata \\ %{}), do: provider().exchange_code(code, metadata)

  @doc "Ensures a personal workspace and selects it when the verified session has no tenant."
  def establish(
        %{current_scope: scope, sealed_session: sealed_session} = authentication,
        metadata \\ %{}
      ) do
    with {:ok, organization} <- Accounts.ensure_personal_organization(scope.user) do
      case scope.organization do
        nil -> switch_organization(sealed_session, organization.id, metadata)
        %{id: _id} -> {:ok, authentication}
      end
    end
  end

  @doc "Verifies an opaque session, refreshing authority when needed."
  def authenticate(sealed_session, metadata \\ %{}),
    do: provider().authenticate(sealed_session, metadata)

  @doc "Switches to a workspace after the provider verifies the requested membership."
  def switch_organization(sealed_session, organization_id, metadata \\ %{}),
    do: provider().switch_organization(sealed_session, organization_id, metadata)

  @doc "Refreshes permissions for the session's current workspace."
  def refresh_claims(sealed_session, metadata \\ %{}),
    do: provider().refresh_claims(sealed_session, metadata)

  @doc "Revokes the provider session and returns its logout destination."
  def logout(sealed_session, return_to \\ nil), do: provider().logout(sealed_session, return_to)

  @doc "Returns the LiveView disconnect topic for a verified session."
  def socket_topic(%{id: session_id}), do: "auth_sessions:#{session_id}"

  @doc "Looks up an organization using the application's provisioning key."
  def get_organization_by_external_id(external_id),
    do: provider().get_organization_by_external_id(external_id)

  @doc "Fetches a normalized organization."
  def get_organization(id), do: provider().get_organization(id)

  @doc "Creates an organization with application-supplied attributes."
  def create_organization(attrs), do: provider().create_organization(attrs)

  @doc "Lists normalized memberships, optionally restricted to an organization."
  def list_memberships(user_id, organization_id \\ nil),
    do: provider().list_memberships(user_id, organization_id)

  @doc "Fetches a normalized membership."
  def get_membership(id), do: provider().get_membership(id)

  @doc "Creates a membership with the requested application role."
  def create_membership(user_id, organization_id, role),
    do: provider().create_membership(user_id, organization_id, role)

  @doc "Updates a membership's role."
  def update_membership(id, role), do: provider().update_membership(id, role)

  @doc "Removes a membership."
  def remove_membership(id), do: provider().remove_membership(id)

  @doc "Invites a member to an organization."
  def invite_member(organization_id, inviter_id, email, role),
    do: provider().invite_member(organization_id, inviter_id, email, role)

  @doc "Fetches current permissions for an application role."
  def get_role(slug), do: provider().get_role(slug)
end
