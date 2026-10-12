defmodule Hermitscale.Auth.WorkOS do
  @moduledoc """
  WorkOS implementation of the application's authentication provider contract.

  WorkOS wire fields and token claims stay within this adapter and its session
  verifier. Callers receive provider-neutral scopes and directory records.
  """

  @behaviour Hermitscale.Auth.Provider

  alias Hermitscale.WorkOS.{Client, Session}

  @impl true
  def authorization_url(state, opts), do: client().authorization_url(state, opts)

  @impl true
  def exchange_code(code, metadata) do
    with {:ok, authentication} <- client().authenticate_with_code(code, metadata),
         {:ok, result} <- Session.create(authentication) do
      {:ok, result}
    else
      {:error, :invalid_authentication_response} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def authenticate(sealed_session, metadata), do: Session.authenticate(sealed_session, metadata)

  @impl true
  def switch_organization(sealed_session, organization_id, metadata),
    do: Session.switch_organization(sealed_session, organization_id, metadata)

  @impl true
  def refresh_claims(sealed_session, metadata),
    do: Session.refresh_claims(sealed_session, metadata)

  @impl true
  def logout(sealed_session, return_to), do: Session.logout(sealed_session, return_to)

  @impl true
  def get_organization_by_external_id(external_id) do
    with {:ok, organization} <- client().get_organization_by_external_id(external_id) do
      normalize_organization(organization)
    end
  end

  @impl true
  def get_organization(organization_id) do
    with {:ok, organization} <- client().get_organization(organization_id) do
      normalize_organization(organization)
    end
  end

  @impl true
  def create_organization(%{external_id: external_id, name: name, metadata: metadata}) do
    with {:ok, organization} <-
           client().create_organization(%{
             "external_id" => external_id,
             "name" => name,
             "metadata" => metadata
           }) do
      normalize_organization(organization)
    end
  end

  @impl true
  def list_memberships(user_id, organization_id) do
    case client().list_memberships(user_id, organization_id) do
      {:ok, %{"data" => memberships}} when is_list(memberships) ->
        normalize_memberships(memberships)

      {:ok, _response} ->
        {:error, :invalid_response}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def get_membership(id) do
    with {:ok, membership} <- client().get_membership(id) do
      normalize_membership(membership)
    end
  end

  @impl true
  def create_membership(user_id, organization_id, role) do
    with {:ok, membership} <- client().create_membership(user_id, organization_id, role) do
      normalize_membership(membership)
    end
  end

  @impl true
  def update_membership(id, role) do
    with {:ok, membership} <- client().update_membership(id, role) do
      normalize_membership(membership)
    end
  end

  @impl true
  def remove_membership(id) do
    with {:ok, _response} <- client().remove_membership(id) do
      :ok
    end
  end

  @impl true
  def invite_member(organization_id, inviter_id, email, role) do
    with {:ok, invitation} <- client().invite_member(organization_id, inviter_id, email, role) do
      normalize_invitation(invitation)
    end
  end

  @impl true
  def get_role(slug) do
    with {:ok, role} <- client().get_role(slug) do
      normalize_role(role)
    end
  end

  defp normalize_organization(organization) when is_map(organization) do
    with {:ok, id} <- required_string(organization, "id"),
         {:ok, name} <- optional_string(organization["name"]),
         {:ok, external_id} <- optional_string(organization["external_id"]),
         {:ok, metadata} <- optional_metadata(organization["metadata"]) do
      {:ok, %{id: id, name: name, external_id: external_id, metadata: metadata}}
    end
  end

  defp normalize_organization(_organization), do: {:error, :invalid_response}

  defp normalize_memberships(memberships) do
    memberships
    |> Enum.reduce_while({:ok, []}, fn membership, {:ok, normalized} ->
      case normalize_membership(membership) do
        {:ok, result} -> {:cont, {:ok, [result | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, memberships} -> {:ok, Enum.reverse(memberships)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_membership(membership) when is_map(membership) do
    with {:ok, id} <- required_string(membership, "id"),
         {:ok, user_id} <- required_string(membership, "user_id"),
         {:ok, organization_id} <- required_string(membership, "organization_id"),
         {:ok, status} <- required_string(membership, "status"),
         {:ok, role} <- role_slug(membership["role"]) do
      {:ok, %{id: id, user_id: user_id, org_id: organization_id, status: status, role: role}}
    end
  end

  defp normalize_membership(_membership), do: {:error, :invalid_response}

  defp normalize_invitation(invitation) when is_map(invitation) do
    with {:ok, id} <- required_string(invitation, "id"),
         {:ok, email} <- required_string(invitation, "email"),
         {:ok, organization_id} <- required_string(invitation, "organization_id"),
         {:ok, role} <- role_slug(invitation["role_slug"]),
         {:ok, state} <- optional_string(invitation["state"]) do
      {:ok, %{id: id, email: email, org_id: organization_id, role: role, state: state}}
    end
  end

  defp normalize_invitation(_invitation), do: {:error, :invalid_response}

  defp normalize_role(role) when is_map(role) do
    with {:ok, slug} <- required_string(role, "slug"),
         {:ok, permissions} <- optional_permissions(role["permissions"]) do
      {:ok, %{slug: slug, permissions: permissions}}
    end
  end

  defp normalize_role(_role), do: {:error, :invalid_response}

  defp required_string(record, key) do
    case record[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, :invalid_response}
    end
  end

  defp optional_string(nil), do: {:ok, nil}
  defp optional_string(value) when is_binary(value), do: {:ok, value}
  defp optional_string(_value), do: {:error, :invalid_response}

  defp optional_metadata(nil), do: {:ok, %{}}
  defp optional_metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  defp optional_metadata(_metadata), do: {:error, :invalid_response}

  defp role_slug(nil), do: {:ok, nil}
  defp role_slug(slug) when is_binary(slug) and slug != "", do: {:ok, slug}
  defp role_slug(%{"slug" => slug}) when is_binary(slug) and slug != "", do: {:ok, slug}
  defp role_slug(_role), do: {:error, :invalid_response}

  defp optional_permissions(nil), do: {:ok, []}

  defp optional_permissions(permissions) when is_list(permissions) do
    case Enum.all?(permissions, &(is_binary(&1) and &1 != "")) do
      true -> {:ok, permissions}
      false -> {:error, :invalid_response}
    end
  end

  defp optional_permissions(_permissions), do: {:error, :invalid_response}

  defp client, do: Client.adapter(__MODULE__)
end
