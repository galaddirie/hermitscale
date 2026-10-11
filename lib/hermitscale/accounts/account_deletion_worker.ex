defmodule Hermitscale.Accounts.AccountDeletionWorker do
  @moduledoc """
  Durable user-deletion saga for WorkOS sessions, Pipes accounts, and local PII.
  """

  use Oban.Worker,
    queue: :workos,
    max_attempts: 12,
    unique: [
      period: :infinity,
      fields: [:args],
      keys: [:user_id],
      states: :incomplete
    ]

  alias Hermitscale.Accounts
  alias Hermitscale.Accounts.User
  alias Hermitscale.Integrations.ConnectedAccounts
  alias Hermitscale.Repo
  alias Hermitscale.WorkOS.{Client, Session}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case Repo.get(User, user_id) do
      nil ->
        :ok

      %User{deleted_at: %DateTime{}} ->
        :ok

      %User{} = user ->
        delete_user(user)
    end
  end

  defp delete_user(user) do
    {:ok, _revoked_count} = Session.revoke_all_for_user(user)

    with :ok <- revoke_workos_sessions(user),
         :ok <- disconnect_accounts(user),
         :ok <- delete_workos_user(user),
         {:ok, tombstoned_user} <- Accounts.tombstone_workos_user(user.workos_user_id) do
      ConnectedAccounts.tombstone_owned_by(tombstoned_user)
      :ok
    end
  end

  defp revoke_workos_sessions(user) do
    user
    |> Session.list_for_user()
    |> Enum.reduce_while(:ok, fn session, :ok ->
      case client().revoke_session(session.workos_session_id) do
        {:ok, _body} -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:session_revocation_failed, reason}}}
      end
    end)
  end

  defp disconnect_accounts(user) do
    user
    |> ConnectedAccounts.list_owned_by()
    |> Enum.reduce_while(:ok, fn account, :ok ->
      case account.state do
        :disconnected ->
          {:cont, :ok}

        _state ->
          case ConnectedAccounts.disconnect_account(account) do
            {:ok, _account} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:connected_account_cleanup_failed, reason}}}
          end
      end
    end)
  end

  defp delete_workos_user(%User{workos_user_id: workos_user_id})
       when is_binary(workos_user_id) do
    case client().delete_user(workos_user_id) do
      {:ok, _body} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:workos_user_deletion_failed, reason}}
    end
  end

  defp delete_workos_user(%User{workos_user_id: nil}), do: :ok

  defp client do
    Application.get_env(:hermitscale, __MODULE__, [])[:client] || Client
  end
end
