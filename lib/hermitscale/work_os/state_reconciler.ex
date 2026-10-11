defmodule Hermitscale.WorkOS.StateReconciler do
  @moduledoc """
  Periodic full-state repair for WorkOS users, organizations, memberships,
  sessions, and supported Pipes connected accounts.

  Missing-object mutations run only after every remote page has completed
  successfully. The persisted generation record makes interrupted scans
  visible and prevents a partial scan from being mistaken for convergence.
  """

  use Oban.Worker,
    queue: :workos,
    max_attempts: 8,
    unique: [
      period: 23 * 60 * 60,
      fields: [:worker],
      states: :incomplete
    ]

  import Ecto.Query

  alias Hermitscale.Accounts
  alias Hermitscale.Accounts.AccountDeletionWorker
  alias Hermitscale.Integrations.ConnectedAccounts
  alias Hermitscale.Repo

  alias Hermitscale.WorkOS.{
    AuthSession,
    Client,
    EventsConsumer,
    Session,
    StateReconciliation
  }

  @stale_running_seconds 6 * 60 * 60
  @event_race_window_seconds 5 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case reconcile() do
      {:ok, _reconciliation} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs one complete reconciliation generation.
  """
  def reconcile do
    expire_abandoned_generations()
    started_at = DateTime.utc_now(:microsecond)

    case start_generation(started_at) do
      {:ok, generation} ->
        reconcile_generation(generation)

      {:error, %Ecto.Changeset{} = changeset} ->
        case changeset.errors[:status] do
          {_message, [constraint: :unique, constraint_name: _name]} ->
            {:ok, :already_running}

          _other ->
            {:error, :generation_start_failed}
        end
    end
  end

  defp reconcile_generation(generation) do
    try do
      with {:ok, remote_users, user_count} <- scan_users(),
           {:ok, remote_organizations, organization_count} <- scan_organizations(),
           {:ok, remote_memberships, membership_count} <-
             scan_memberships(remote_organizations),
           {:ok, remote_sessions, session_count} <- scan_sessions(remote_users),
           {:ok, remote_accounts, scanned_pairs, connected_account_count} <-
             scan_connected_accounts(remote_users, remote_organizations),
           {:ok, missing_user_count} <-
             reconcile_missing_users(remote_users, generation.started_at),
           {:ok, missing_organization_count} <-
             reconcile_missing_organizations(
               remote_organizations,
               generation.started_at
             ),
           {:ok, missing_membership_count} <-
             reconcile_missing_memberships(
               remote_memberships,
               generation.started_at
             ),
           {:ok, missing_session_count} <-
             reconcile_missing_sessions(remote_sessions, generation.started_at),
           {:ok, missing_account_count} <-
             ConnectedAccounts.mark_missing_from_reconciliation(
               remote_accounts,
               scanned_pairs,
               generation.started_at
             ),
           {:ok, _cursor} <-
             generation.started_at
             |> DateTime.add(-@event_race_window_seconds, :second)
             |> EventsConsumer.reset_from(),
           {:ok, _job} <- %{} |> EventsConsumer.new() |> Oban.insert() do
        counts = %{
          "users" => user_count,
          "organizations" => organization_count,
          "memberships" => membership_count,
          "sessions" => session_count,
          "connected_accounts" => connected_account_count,
          "missing_users" => missing_user_count,
          "missing_organizations" => missing_organization_count,
          "missing_memberships" => missing_membership_count,
          "missing_sessions" => missing_session_count,
          "missing_connected_accounts" => missing_account_count
        }

        complete_generation(generation, counts)
      else
        {:error, reason} -> fail_generation(generation, reason)
      end
    rescue
      exception ->
        fail_generation(generation, {:exception, exception.__struct__})
    catch
      kind, _reason ->
        fail_generation(generation, {:caught, kind})
    end
  end

  defp scan_users do
    scan_pages(
      &client().list_users(&1),
      fn user ->
        with {:ok, _local_user} <- Accounts.upsert_from_workos(user),
             {:ok, id} <- remote_id(user) do
          {:ok, id}
        end
      end
    )
  end

  defp scan_organizations do
    scan_pages(
      &client().list_organizations(&1),
      fn organization ->
        with {:ok, _local_organization} <-
               Accounts.sync_workos_organization(organization, :upsert),
             {:ok, id} <- remote_id(organization) do
          {:ok, id}
        end
      end
    )
  end

  defp scan_memberships(remote_organizations) do
    Accounts.list_workos_organizations_for_reconciliation()
    |> Enum.filter(&MapSet.member?(remote_organizations, &1.workos_organization_id))
    |> Enum.reduce_while({:ok, MapSet.new(), 0}, fn organization, {:ok, seen, count} ->
      result =
        scan_pages(
          &client().list_organization_memberships(
            organization.workos_organization_id,
            &1
          ),
          fn membership ->
            with {:ok, _local_membership} <-
                   Accounts.sync_workos_membership(membership, :upsert),
                 {:ok, id} <- remote_id(membership) do
              {:ok, id}
            end
          end
        )

      case result do
        {:ok, page_seen, page_count} ->
          {:cont, {:ok, MapSet.union(seen, page_seen), count + page_count}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp scan_sessions(remote_users) do
    Accounts.list_workos_users_for_reconciliation()
    |> Enum.filter(&MapSet.member?(remote_users, &1.workos_user_id))
    |> Enum.reduce_while({:ok, MapSet.new(), 0}, fn user, {:ok, seen, count} ->
      result =
        scan_pages(
          &client().list_sessions(user.workos_user_id, &1),
          &remote_id/1
        )

      case result do
        {:ok, page_seen, page_count} ->
          {:cont, {:ok, MapSet.union(seen, page_seen), count + page_count}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp scan_connected_accounts(remote_users, remote_organizations) do
    configured = ConnectedAccounts.configured_provider_slugs()

    ConnectedAccounts.reconciliation_targets()
    |> Enum.filter(fn {owner, organization} ->
      MapSet.member?(remote_users, owner.workos_user_id) and
        (organization.personal or
           MapSet.member?(
             remote_organizations,
             organization.workos_organization_id
           ))
    end)
    |> Enum.reduce_while(
      {:ok, MapSet.new(), MapSet.new(), 0},
      fn {owner, organization}, {:ok, seen, scanned_pairs, count} ->
        case client().list_providers(
               owner.workos_user_id,
               organization.workos_organization_id
             ) do
          {:ok, %{"data" => providers}} when is_list(providers) ->
            case apply_provider_snapshots(
                   providers,
                   owner,
                   organization,
                   configured,
                   seen,
                   count
                 ) do
              {:ok, seen, count} ->
                pair = {owner.id, organization.id}

                {:cont, {:ok, seen, MapSet.put(scanned_pairs, pair), count}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end

          {:ok, _invalid_body} ->
            {:halt, {:error, :invalid_providers_response}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    )
  end

  defp apply_provider_snapshots(
         providers,
         owner,
         organization,
         configured,
         initial_seen,
         initial_count
       ) do
    Enum.reduce_while(
      providers,
      {:ok, initial_seen, initial_count},
      fn provider, {:ok, seen, count} ->
        slug = provider["slug"]
        connected_account = provider["connected_account"]

        cond do
          not MapSet.member?(configured, slug) ->
            {:cont, {:ok, seen, count}}

          not is_map(connected_account) ->
            {:cont, {:ok, seen, count}}

          true ->
            remote_account =
              connected_account
              |> Map.put("provider_slug", slug)
              |> Map.put("user_id", owner.workos_user_id)
              |> Map.put(
                "organization_id",
                organization.workos_organization_id
              )

            event_type =
              if remote_account["state"] == "needs_reauthorization",
                do: "pipes.connected_account.reauthorization_needed",
                else: "pipes.connected_account.connected"

            with {:ok, account} <-
                   ConnectedAccounts.sync_event(event_type, remote_account) do
              {:cont, {:ok, MapSet.put(seen, account.workos_connected_account_id), count + 1}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end
      end
    )
  end

  defp reconcile_missing_users(remote_users, observed_at) do
    Accounts.list_workos_users_for_reconciliation()
    |> Enum.filter(fn user ->
      not MapSet.member?(remote_users, user.workos_user_id) and
        observed_after?(observed_at, user.workos_updated_at || user.inserted_at)
    end)
    |> Enum.reduce_while({:ok, 0}, fn user, {:ok, count} ->
      with {:ok, user} <-
             Accounts.request_account_deletion_by_workos_id(
               user.workos_user_id,
               DateTime.truncate(observed_at, :second)
             ),
           {:ok, _revoked_count} <- Session.revoke_all_for_user(user),
           {:ok, _job} <-
             %{"user_id" => user.id}
             |> AccountDeletionWorker.new()
             |> Oban.insert() do
        {:cont, {:ok, count + 1}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reconcile_missing_organizations(remote_organizations, observed_at) do
    Accounts.list_workos_organizations_for_reconciliation()
    |> Enum.filter(fn organization ->
      not MapSet.member?(
        remote_organizations,
        organization.workos_organization_id
      ) and
        observed_after?(
          observed_at,
          organization.workos_updated_at || organization.inserted_at
        )
    end)
    |> apply_missing(fn organization ->
      with {:ok, result} <-
             Accounts.mark_workos_organization_missing(
               organization.workos_organization_id,
               observed_at
             ),
           {:ok, _count} <- Session.revoke_for_organization(organization.id) do
        ConnectedAccounts.disable_for_organization(organization.id)
        {:ok, result}
      end
    end)
  end

  defp reconcile_missing_memberships(remote_memberships, observed_at) do
    Accounts.list_workos_memberships_for_reconciliation()
    |> Enum.filter(fn membership ->
      not MapSet.member?(
        remote_memberships,
        membership.workos_membership_id
      ) and
        observed_after?(
          observed_at,
          membership.workos_updated_at || membership.inserted_at
        )
    end)
    |> apply_missing(fn membership ->
      with {:ok, result} <-
             Accounts.mark_workos_membership_missing(
               membership.workos_membership_id,
               observed_at
             ),
           {:ok, _count} <-
             Session.revoke_for_user_organization(
               membership.user_id,
               membership.org_id
             ) do
        ConnectedAccounts.disable_for_owner_organization(
          membership.user_id,
          membership.org_id
        )

        {:ok, result}
      end
    end)
  end

  defp reconcile_missing_sessions(remote_sessions, observed_at) do
    sessions =
      Repo.all(
        from session in AuthSession,
          where: is_nil(session.revoked_at)
      )

    sessions
    |> Enum.filter(fn session ->
      not MapSet.member?(remote_sessions, session.workos_session_id) and
        observed_after?(observed_at, session.inserted_at)
    end)
    |> apply_missing(fn session ->
      Session.revoke_by_workos_session_id(session.workos_session_id)
    end)
  end

  defp apply_missing(objects, callback) do
    Enum.reduce_while(objects, {:ok, 0}, fn object, {:ok, count} ->
      case callback.(object) do
        {:ok, _result} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp scan_pages(fetch_page, apply_object) do
    do_scan_pages(fetch_page, apply_object, nil, MapSet.new(), 0)
  end

  defp do_scan_pages(fetch_page, apply_object, cursor, seen, count) do
    case fetch_page.(cursor) do
      {:ok, %{"data" => objects} = response} when is_list(objects) ->
        with {:ok, seen, count} <-
               apply_page(objects, apply_object, seen, count),
             {:ok, next_cursor} <- next_page_cursor(response, cursor) do
          case next_cursor do
            nil ->
              {:ok, seen, count}

            value ->
              do_scan_pages(
                fetch_page,
                apply_object,
                value,
                seen,
                count
              )
          end
        end

      {:ok, _invalid_body} ->
        {:error, :invalid_state_api_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_page(objects, apply_object, initial_seen, initial_count) do
    Enum.reduce_while(
      objects,
      {:ok, initial_seen, initial_count},
      fn object, {:ok, seen, count} ->
        case apply_object.(object) do
          {:ok, id} when is_binary(id) ->
            {:cont, {:ok, MapSet.put(seen, id), count + 1}}

          {:error, reason} ->
            {:halt, {:error, reason}}

          _invalid ->
            {:halt, {:error, :invalid_state_object}}
        end
      end
    )
  end

  defp next_page_cursor(response, current_cursor) do
    case get_in(response, ["list_metadata", "after"]) do
      nil ->
        {:ok, nil}

      next when is_binary(next) and next != "" and next != current_cursor ->
        {:ok, next}

      _invalid ->
        {:error, :invalid_state_api_cursor}
    end
  end

  defp remote_id(%{"id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp remote_id(_object), do: {:error, :missing_state_object_id}

  defp observed_after?(observed_at, local_timestamp) do
    DateTime.after?(observed_at, local_timestamp)
  end

  defp start_generation(started_at) do
    %StateReconciliation{}
    |> StateReconciliation.start_changeset(%{
      status: :running,
      started_at: started_at
    })
    |> Repo.insert()
  end

  defp complete_generation(generation, counts) do
    completed_at = DateTime.utc_now(:microsecond)

    result =
      generation
      |> StateReconciliation.complete_changeset(%{
        status: :completed,
        completed_at: completed_at,
        object_counts: counts,
        error: nil
      })
      |> Repo.update()

    :telemetry.execute(
      [:hermitscale, :workos, :reconciliation],
      %{duration: DateTime.diff(completed_at, generation.started_at, :millisecond)},
      %{status: :completed, generation_id: generation.id}
    )

    result
  end

  defp fail_generation(generation, reason) do
    completed_at = DateTime.utc_now(:microsecond)

    _result =
      generation
      |> StateReconciliation.complete_changeset(%{
        status: :failed,
        completed_at: completed_at,
        object_counts: %{},
        error: diagnostic(reason)
      })
      |> Repo.update()

    :telemetry.execute(
      [:hermitscale, :workos, :reconciliation],
      %{duration: DateTime.diff(completed_at, generation.started_at, :millisecond)},
      %{status: :failed, generation_id: generation.id}
    )

    {:error, reason}
  end

  defp expire_abandoned_generations do
    cutoff =
      DateTime.utc_now(:microsecond)
      |> DateTime.add(-@stale_running_seconds, :second)

    now = DateTime.utc_now(:microsecond)

    from(reconciliation in StateReconciliation,
      where:
        reconciliation.status == :running and
          reconciliation.started_at < ^cutoff
    )
    |> Repo.update_all(
      set: [
        status: :failed,
        completed_at: now,
        error: "abandoned generation",
        updated_at: now
      ]
    )
  end

  defp diagnostic(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 1_000)
    |> String.slice(0, 2_000)
  end

  defp client do
    Application.get_env(:hermitscale, __MODULE__, [])[:client] || Client
  end
end
