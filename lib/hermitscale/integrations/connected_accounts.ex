defmodule Hermitscale.Integrations.ConnectedAccounts do
  @moduledoc """
  Resolves provider credentials directly through WorkOS Pipes.

  WorkOS owns connection state, consent, and provider tokens. This module does
  not persist or synchronize accounts, tokens, sharing grants, or events.
  """

  alias Hermitscale.Integrations.CredentialRef
  alias Hermitscale.WorkOS.Client

  @providers %{"google.oauth" => "google"}

  @doc """
  Builds a reference using trusted WorkOS user and organization identities.
  """
  def credential_ref({"org_" <> _ = organization_id, "user_" <> _ = user_id}, provider_id, scopes)
      when is_list(scopes) do
    case Map.fetch(@providers, provider_id) do
      {:ok, slug} ->
        {:ok,
         %CredentialRef{
           user_id: user_id,
           organization_id: organization_id,
           provider_id: provider_id,
           provider_slug: slug,
           required_scopes: Enum.uniq(scopes)
         }}

      :error ->
        {:error, :unknown_provider}
    end
  end

  def credential_ref(_identity, _provider_id, _scopes),
    do: {:error, :missing_credential_identity}

  @doc """
  Vends a token for an immediate request, checking WorkOS's current scope grant.
  """
  def fetch_oauth_token(%CredentialRef{} = ref) do
    with {:ok, verified_ref} <-
           credential_ref(
             {ref.organization_id, ref.user_id},
             ref.provider_id,
             ref.required_scopes
           ),
         {:ok, token} <-
           client().fetch_oauth_token(
             verified_ref.provider_slug,
             verified_ref.user_id,
             verified_ref.organization_id
           ),
         :ok <- validate_scopes(token, verified_ref.required_scopes) do
      {:ok, Map.take(token, [:access_token, :expires_at, :scopes])}
    end
  end

  defp validate_scopes(%{missing_scopes: [], scopes: scopes}, required) do
    case Enum.all?(required, &(&1 in scopes)) do
      true -> :ok
      false -> {:error, :insufficient_scopes}
    end
  end

  defp validate_scopes(%{missing_scopes: [_ | _]}, _required),
    do: {:error, :insufficient_scopes}

  defp client do
    Application.get_env(:hermitscale, __MODULE__, [])
    |> Keyword.get(:client, Client)
  end
end
