defmodule Hermitscale.WorkOS.EventProcessor do
  @moduledoc """
  Applies allowlisted WorkOS events to local projections.
  """

  alias Hermitscale.Accounts
  alias Hermitscale.Accounts.{Organization, OrganizationMembership}
  alias Hermitscale.Accounts.AccountDeletionWorker
  alias Hermitscale.Integrations.ConnectedAccounts
  alias Hermitscale.WorkOS.Session

  @event_types [
    "user.created",
    "user.updated",
    "user.deleted",
    "organization.created",
    "organization.updated",
    "organization.deleted",
    "organization_membership.created",
    "organization_membership.updated",
    "organization_membership.deleted",
    "session.revoked",
    "pipes.connected_account.connected",
    "pipes.connected_account.disconnected",
    "pipes.connected_account.reauthorization_needed"
  ]

  @doc "Returns the WorkOS event allowlist consumed from the Events API."
  def event_types, do: @event_types

  @doc """
  Applies one event envelope or classifies an unknown type as ignored.
  """
  def apply(%{"event" => event_type} = envelope) when is_binary(event_type) do
    case {event_type in @event_types, envelope["data"]} do
      {false, _data} -> {:ignored, :unsupported_event_type}
      {true, data} when is_map(data) -> apply_supported(event_type, data, envelope)
      {true, _data} -> {:error, :invalid_event_data}
    end
  end

  def apply(_envelope), do: {:error, :invalid_event_envelope}

  defp apply_supported(event_type, data, _envelope)
       when event_type in ["user.created", "user.updated"] do
    normalize_result(Accounts.upsert_from_workos(data))
  end

  defp apply_supported("user.deleted", data, envelope) do
    with {:ok, workos_user_id} <- required_id(data),
         {:ok, user} <-
           Accounts.request_account_deletion_by_workos_id(
             workos_user_id,
             occurred_at(envelope)
           ) do
      {:ok, _count} = Session.revoke_all_for_user(user)

      case %{"user_id" => user.id}
           |> AccountDeletionWorker.new()
           |> Oban.insert() do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp apply_supported(event_type, data, _envelope)
       when event_type in ["organization.created", "organization.updated"] do
    normalize_result(Accounts.sync_workos_organization(data, :upsert))
  end

  defp apply_supported("organization.deleted", data, envelope) do
    data = put_event_timestamp(data, envelope)

    with {:ok, %Organization{} = organization} <-
           Accounts.sync_workos_organization(data, :delete),
         {:ok, _count} <- Session.revoke_for_organization(organization.id) do
      ConnectedAccounts.disable_for_organization(organization.id)
      :ok
    else
      {:ok, :already_deleted} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp apply_supported(event_type, data, _envelope)
       when event_type in [
              "organization_membership.created",
              "organization_membership.updated"
            ] do
    data
    |> Accounts.sync_workos_membership(:upsert)
    |> apply_membership_result()
  end

  defp apply_supported("organization_membership.deleted", data, envelope) do
    data = put_event_timestamp(data, envelope)

    data
    |> Accounts.sync_workos_membership(:delete)
    |> apply_membership_result()
  end

  defp apply_supported("session.revoked", data, _envelope) do
    with {:ok, workos_session_id} <- required_id(data),
         {:ok, _count} <- Session.revoke_by_workos_session_id(workos_session_id) do
      :ok
    end
  end

  defp apply_supported("pipes." <> _rest = event_type, data, _envelope) do
    data =
      data
      |> copy_if_missing("provider_slug", "data_provider_slug")
      |> copy_if_missing("user_id", "user")

    normalize_result(ConnectedAccounts.sync_event(event_type, data))
  end

  defp normalize_result({:ok, _value}), do: :ok
  defp normalize_result({:error, _reason} = error), do: error

  defp apply_membership_result({:ok, %OrganizationMembership{status: :active}}), do: :ok

  defp apply_membership_result({:ok, %OrganizationMembership{user_id: user_id, org_id: org_id}}) do
    with {:ok, _count} <- Session.revoke_for_user_organization(user_id, org_id) do
      ConnectedAccounts.disable_for_owner_organization(user_id, org_id)
      :ok
    end
  end

  defp apply_membership_result({:ok, :already_deleted}), do: :ok
  defp apply_membership_result({:error, _reason} = error), do: error

  defp required_id(%{"id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp required_id(%{id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp required_id(_data), do: {:error, :missing_event_object_id}

  defp occurred_at(%{"created_at" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      {:error, _reason} -> DateTime.utc_now(:second)
    end
  end

  defp occurred_at(_envelope), do: DateTime.utc_now(:second)

  defp copy_if_missing(data, destination, source) do
    case {Map.get(data, destination), Map.get(data, source)} do
      {nil, value} when is_binary(value) -> Map.put(data, destination, value)
      _values -> data
    end
  end

  defp put_event_timestamp(data, envelope) do
    case {Map.get(data, "updated_at"), Map.get(envelope, "created_at")} do
      {nil, created_at} when is_binary(created_at) -> Map.put(data, "updated_at", created_at)
      _timestamps -> data
    end
  end
end
