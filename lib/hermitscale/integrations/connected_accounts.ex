defmodule Hermitscale.Integrations.ConnectedAccounts do
  @moduledoc """
  Tenant-scoped connected-account metadata and WorkOS Pipes authorization.

  Provider secrets are never stored here. OAuth tokens are vended only from
  `fetch_oauth_token/4`, immediately before a provider request.
  """

  import Ecto.Query

  alias Hermitscale.Accounts
  alias Hermitscale.Accounts.{Organization, OrganizationMembership, Scope, User}

  alias Hermitscale.Integrations.{
    ConnectedAccount,
    ConnectedAccountIntent,
    CredentialImpacts,
    CredentialRef
  }

  alias Hermitscale.Repo
  alias Hermitscale.WorkOS.Client

  @intent_lifetime_seconds 15 * 60
  @intent_token_bytes 24

  @doc """
  Lists allowlisted provider cards for the active user and organization.
  """
  def list_for_scope(%Scope{} = scope) do
    org_id = Scope.organization_id!(scope)

    local_accounts =
      ConnectedAccount
      |> where(
        [account],
        account.owner_user_id == ^scope.user.id and account.org_id == ^org_id and
          is_nil(account.deleted_at)
      )
      |> Repo.all()
      |> Map.new(&{&1.provider_slug, &1})

    remote_providers = remote_provider_index(scope)

    configured_providers()
    |> Enum.map(fn provider ->
      remote = Map.get(remote_providers, provider.slug, %{})

      provider
      |> Map.put(:id, provider.slug)
      |> Map.put(:remote, remote)
      |> Map.put(:connection, Map.get(local_accounts, provider.slug))
    end)
  end

  @doc """
  Creates an expiring local consent intent and returns the Pipes authorization URL.
  """
  def begin_connect(%Scope{} = scope, provider_slug, sharing_mode, return_to)
      when is_binary(provider_slug) and is_binary(return_to) do
    with {:ok, provider} <- fetch_provider(provider_slug),
         :ok <- validate_connect_scope(scope, sharing_mode),
         true <- is_nil(scope.user.deletion_pending_at) and is_nil(scope.user.deleted_at),
         true <- is_binary(scope.user.workos_user_id),
         token <- random_intent_token(),
         {:ok, intent} <-
           insert_intent(scope, provider, sharing_mode, token),
         {:ok, %{"url" => url}} <-
           client().authorize_connection(
             provider.slug,
             scope.user.workos_user_id,
             scope.organization.workos_organization_id,
             append_intent(return_to, token)
           ) do
      {:ok, %{url: url, intent: intent}}
    else
      false -> {:error, :workos_user_unavailable}
      {:ok, _invalid_body} -> {:error, :invalid_authorization_response}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Reconciles a just-finished authorization when the browser returns before its event.
  """
  def refresh_intent(%Scope{} = scope, token) when is_binary(token) do
    with {:ok, intent} <- load_intent(scope, token),
         {:ok, remote_account} <-
           client().get_connected_account(
             intent.provider_slug,
             scope.user.workos_user_id,
             intent.organization.workos_organization_id
           ),
         {:ok, account} <- upsert_from_intent(intent, remote_account),
         {:ok, _intent} <- consume_intent(intent) do
      {:ok, account}
    end
  end

  @doc """
  Immediately blocks vending, then disconnects the WorkOS account.
  """
  def disconnect(%Scope{} = scope, provider_slug) when is_binary(provider_slug) do
    case account_for_scope(scope, provider_slug) do
      %ConnectedAccount{} = account ->
        disconnect_account(account)

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Changes the local organization-sharing grant for an existing connection.

  Removing an organization grant blocks vending and disables dependent
  triggers immediately; it does not delete the provider connection.
  """
  def set_sharing(%Scope{} = scope, provider_slug, sharing_mode)
      when is_binary(provider_slug) and sharing_mode in [:private, :organization] do
    with %ConnectedAccount{} = account <- account_for_scope(scope, provider_slug),
         :ok <- sharing_change_allowed?(account),
         :ok <- validate_connect_scope(scope, sharing_mode),
         {:ok, account} <-
           account
           |> ConnectedAccount.sharing_changeset(%{sharing_mode: sharing_mode})
           |> Repo.update() do
      if sharing_mode == :private and not account.organization.personal do
        CredentialImpacts.disable_triggers(account)
      end

      {:ok, account}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def disconnect_account(%ConnectedAccount{} = account) do
    account = Repo.preload(account, [:owner, :organization])

    with {:ok, blocking_account} <-
           account
           |> ConnectedAccount.state_changeset(%{state: :disconnecting})
           |> Repo.update(),
         _disabled_count <- CredentialImpacts.disable_triggers(blocking_account),
         :ok <- delete_remote_account(blocking_account) do
      finalize_disconnection(blocking_account)
    end
  end

  @doc """
  Tombstones every connected account owned by a deleted user.
  """
  def tombstone_owned_by(%User{} = owner) do
    now = DateTime.utc_now(:second)

    from(account in ConnectedAccount, where: account.owner_user_id == ^owner.id)
    |> Repo.update_all(
      set: [state: :disconnected, disconnected_at: now, deleted_at: now, updated_at: now]
    )
  end

  @doc """
  Creates a non-secret runtime reference after validating tenant and provider.
  """
  def credential_ref(organization_id, provider_id, connected_account_id, required_scopes)
      when is_binary(organization_id) and is_binary(provider_id) and
             is_binary(connected_account_id) and is_list(required_scopes) do
    with %ConnectedAccount{} = account <-
           scoped_account(organization_id, provider_id, connected_account_id),
         :ok <- usable_account?(account),
         :ok <- scopes_granted?(required_scopes, account.granted_scopes) do
      {:ok,
       %CredentialRef{
         id: account.id,
         organization_id: organization_id,
         provider_id: provider_id,
         provider_slug: account.provider_slug,
         required_scopes: Enum.uniq(required_scopes)
       }}
    else
      nil -> {:error, :connected_account_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Authorizes and vends an OAuth token for one immediate provider request.
  """
  def fetch_oauth_token(organization_id, provider_id, connected_account_id, required_scopes)
      when is_binary(organization_id) and is_binary(provider_id) and
             is_binary(connected_account_id) and is_list(required_scopes) do
    with %ConnectedAccount{} = account <-
           scoped_account(organization_id, provider_id, connected_account_id),
         :ok <- usable_account?(account),
         :ok <- scopes_granted?(required_scopes, account.granted_scopes),
         {:ok, token} <-
           client().fetch_oauth_token(
             account.provider_slug,
             account.owner.workos_user_id,
             account.workos_organization_id
           ),
         :ok <- no_missing_scopes?(token.missing_scopes),
         :ok <- scopes_granted?(required_scopes, token.scopes) do
      {:ok,
       %{
         access_token: token.access_token,
         expires_at: token.expires_at,
         scopes: token.scopes
       }}
    else
      nil ->
        {:error, :connected_account_not_found}

      {:error, reason} when reason in [:needs_reauthorization, :not_installed] ->
        mark_reauthorization_needed(connected_account_id)
        {:error, reason}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Applies a Pipes connected-account event idempotently.
  """
  def sync_event(event_type, remote_account)
      when is_binary(event_type) and is_map(remote_account) do
    with {:ok, workos_user_id} <- required_string(remote_account, "user_id"),
         %User{} = owner <- Accounts.get_user_by_workos_id(workos_user_id),
         {:ok, provider_slug} <- required_string(remote_account, "provider_slug"),
         {:ok, organization} <- event_organization(owner, provider_slug, remote_account),
         {:ok, attrs} <-
           remote_account_attrs(owner, organization, provider_slug, remote_account, event_type),
         {:ok, account} <- upsert_remote_account(attrs) do
      apply_state_impacts(account)
      {:ok, account}
    else
      nil -> {:error, :unmapped_connected_account_owner}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Lists non-tombstoned connected accounts owned by a user.
  """
  def list_owned_by(%User{} = owner) do
    Repo.all(
      from account in ConnectedAccount,
        where: account.owner_user_id == ^owner.id and is_nil(account.deleted_at),
        preload: [:owner, :organization]
    )
  end

  @doc false
  def configured_provider_slugs do
    configured_providers()
    |> Enum.map(& &1.slug)
    |> MapSet.new()
  end

  @doc false
  def reconciliation_targets do
    membership_targets =
      Accounts.list_workos_users_for_reconciliation()
      |> Enum.flat_map(fn owner ->
        owner
        |> Accounts.list_user_organizations()
        |> Enum.map(&{owner, &1})
      end)

    account_targets =
      Repo.all(
        from account in ConnectedAccount,
          where: is_nil(account.deleted_at),
          preload: [:owner, :organization]
      )
      |> Enum.map(&{&1.owner, &1.organization})

    (membership_targets ++ account_targets)
    |> Enum.uniq_by(fn {owner, organization} -> {owner.id, organization.id} end)
  end

  @doc false
  def disable_for_owner_organization(owner_user_id, organization_id)
      when is_integer(owner_user_id) and is_binary(organization_id) do
    accounts =
      Repo.all(
        from account in ConnectedAccount,
          where:
            account.owner_user_id == ^owner_user_id and
              account.org_id == ^organization_id and
              is_nil(account.deleted_at)
      )

    Enum.reduce(accounts, 0, fn account, count ->
      count + CredentialImpacts.disable_triggers(account)
    end)
  end

  @doc false
  def disable_for_organization(organization_id) when is_binary(organization_id) do
    accounts =
      Repo.all(
        from account in ConnectedAccount,
          where: account.org_id == ^organization_id and is_nil(account.deleted_at)
      )

    Enum.reduce(accounts, 0, fn account, count ->
      count + CredentialImpacts.disable_triggers(account)
    end)
  end

  @doc false
  def mark_missing_from_reconciliation(remote_ids, scanned_pairs, observed_at)
      when is_struct(remote_ids, MapSet) and is_struct(scanned_pairs, MapSet) and
             is_struct(observed_at, DateTime) do
    accounts =
      Repo.all(
        from account in ConnectedAccount,
          where:
            account.backend == :workos_pipes and is_nil(account.deleted_at) and
              not is_nil(account.workos_connected_account_id) and
              account.state not in [:disconnected],
          preload: [:owner, :organization]
      )

    Enum.reduce_while(accounts, {:ok, 0}, fn account, {:ok, count} ->
      missing? =
        MapSet.member?(scanned_pairs, {account.owner_user_id, account.org_id}) and
          not MapSet.member?(remote_ids, account.workos_connected_account_id) and
          observed_after_account?(observed_at, account)

      case missing? do
        false ->
          {:cont, {:ok, count}}

        true ->
          case mark_disconnected(account, observed_at) do
            {:ok, _account} -> {:cont, {:ok, count + 1}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  @doc """
  Validates that a Pipes authorization redirect stays on an approved HTTPS host.
  """
  def authorization_url_allowed?(url) when is_binary(url) do
    allowed_hosts =
      Application.get_env(:hermitscale, __MODULE__, [])
      |> Keyword.get(:authorization_hosts, ["api.workos.com"])

    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) ->
        Enum.any?(allowed_hosts, &host_allowed?(host, &1))

      _other ->
        false
    end
  end

  def authorization_url_allowed?(_url), do: false

  defp account_for_scope(%Scope{} = scope, provider_slug) do
    org_id = Scope.organization_id!(scope)

    Repo.one(
      from account in ConnectedAccount,
        where:
          account.owner_user_id == ^scope.user.id and account.org_id == ^org_id and
            account.provider_slug == ^provider_slug and is_nil(account.deleted_at),
        preload: [:owner, :organization]
    )
  end

  defp scoped_account(organization_id, provider_id, connected_account_id) do
    Repo.one(
      from account in ConnectedAccount,
        where:
          account.id == ^connected_account_id and account.org_id == ^organization_id and
            account.provider_id == ^provider_id and is_nil(account.deleted_at),
        preload: [:owner, :organization]
    )
  end

  defp usable_account?(
         %ConnectedAccount{
           state: :connected,
           organization: organization,
           owner: %User{deletion_pending_at: nil, deleted_at: nil} = owner
         } = account
       ) do
    with %OrganizationMembership{} <-
           Accounts.get_user_membership(owner, organization.id),
         :ok <- sharing_granted?(account, organization) do
      :ok
    else
      nil -> {:error, :owner_membership_inactive}
      {:error, _reason} = error -> error
    end
  end

  defp usable_account?(%ConnectedAccount{state: :needs_reauthorization}),
    do: {:error, :needs_reauthorization}

  defp usable_account?(%ConnectedAccount{
         owner: %User{deletion_pending_at: %DateTime{}}
       }),
       do: {:error, :connected_account_owner_unavailable}

  defp usable_account?(%ConnectedAccount{owner: %User{deleted_at: %DateTime{}}}),
    do: {:error, :connected_account_owner_unavailable}

  defp usable_account?(%ConnectedAccount{}), do: {:error, :connected_account_unavailable}

  defp sharing_granted?(%ConnectedAccount{}, %Organization{personal: true}), do: :ok
  defp sharing_granted?(%ConnectedAccount{sharing_mode: :organization}, %Organization{}), do: :ok
  defp sharing_granted?(_account, _organization), do: {:error, :organization_grant_required}

  defp scopes_granted?(required_scopes, granted_scopes) do
    missing = MapSet.difference(MapSet.new(required_scopes), MapSet.new(granted_scopes))

    case MapSet.size(missing) do
      0 -> :ok
      _count -> {:error, {:missing_scopes, missing |> MapSet.to_list() |> Enum.sort()}}
    end
  end

  defp no_missing_scopes?([]), do: :ok
  defp no_missing_scopes?(missing), do: {:error, {:missing_scopes, Enum.sort(missing)}}

  defp mark_reauthorization_needed(connected_account_id) do
    case Repo.get(ConnectedAccount, connected_account_id) do
      %ConnectedAccount{} = account ->
        account
        |> ConnectedAccount.state_changeset(%{state: :needs_reauthorization})
        |> Repo.update()

      nil ->
        {:ok, :not_found}
    end
  end

  defp delete_remote_account(account) do
    case client().delete_connected_account(
           account.provider_slug,
           account.owner.workos_user_id,
           account.workos_organization_id
         ) do
      {:ok, _body} -> :ok
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp finalize_disconnection(account) do
    account
    |> ConnectedAccount.state_changeset(%{
      state: :disconnected,
      disconnected_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
  end

  defp mark_disconnected(account, observed_at) do
    with {:ok, account} <-
           account
           |> ConnectedAccount.state_changeset(%{
             state: :disconnected,
             disconnected_at: observed_at
           })
           |> Repo.update() do
      CredentialImpacts.disable_triggers(account)
      {:ok, account}
    end
  end

  defp observed_after_account?(observed_at, account) do
    local_timestamp = account.workos_updated_at || account.inserted_at
    DateTime.after?(observed_at, local_timestamp)
  end

  defp insert_intent(scope, provider, sharing_mode, token) do
    %ConnectedAccountIntent{}
    |> ConnectedAccountIntent.changeset(%{
      token_hash: token_hash(token),
      owner_user_id: scope.user.id,
      org_id: Scope.organization_id!(scope),
      provider_id: provider.provider_id,
      provider_slug: provider.slug,
      sharing_mode: sharing_mode,
      expires_at: DateTime.add(DateTime.utc_now(:second), @intent_lifetime_seconds, :second)
    })
    |> Repo.insert()
  end

  defp load_intent(scope, token) do
    hash = token_hash(token)
    org_id = Scope.organization_id!(scope)

    case Repo.one(
           from intent in ConnectedAccountIntent,
             where:
               intent.token_hash == ^hash and intent.owner_user_id == ^scope.user.id and
                 intent.org_id == ^org_id,
             preload: [:owner, :organization]
         ) do
      %ConnectedAccountIntent{consumed_at: nil, expires_at: expires_at} = intent ->
        with true <- DateTime.after?(expires_at, DateTime.utc_now(:second)),
             true <- Plug.Crypto.secure_compare(intent.token_hash, hash) do
          {:ok, intent}
        else
          false -> {:error, :invalid_intent}
        end

      _other ->
        {:error, :invalid_intent}
    end
  end

  defp consume_intent(intent) do
    intent
    |> ConnectedAccountIntent.changeset(%{consumed_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  defp upsert_from_intent(intent, remote_account) do
    remote_account =
      remote_account
      |> Map.put_new("provider_slug", intent.provider_slug)
      |> Map.put_new("user_id", intent.owner.workos_user_id)
      |> Map.put_new("organization_id", intent.organization.workos_organization_id)

    with {:ok, attrs} <-
           remote_account_attrs(
             intent.owner,
             intent.organization,
             intent.provider_slug,
             remote_account,
             "pipes.connected_account.connected",
             intent
           ) do
      upsert_remote_account(attrs)
    end
  end

  defp upsert_remote_account(attrs) do
    case find_remote_account(attrs) do
      nil ->
        create_remote_account(attrs)

      %ConnectedAccount{} = account ->
        with :ok <- assert_same_mapping(account, attrs) do
          update_remote_account(account, attrs)
        end
    end
  end

  defp create_remote_account(attrs) do
    attrs = Map.update(attrs, :sharing_mode, :private, &(&1 || :private))

    %ConnectedAccount{}
    |> ConnectedAccount.create_changeset(attrs)
    |> Repo.insert()
  end

  defp update_remote_account(account, attrs) do
    case newer_projection?(attrs.workos_updated_at, account.workos_updated_at) do
      true ->
        attrs =
          if is_nil(attrs.sharing_mode),
            do: Map.delete(attrs, :sharing_mode),
            else: attrs

        account
        |> ConnectedAccount.sync_changeset(attrs)
        |> Repo.update()

      false ->
        maybe_apply_intent_sharing(account, attrs.sharing_mode)
    end
  end

  defp maybe_apply_intent_sharing(account, sharing_mode)
       when sharing_mode in [:private, :organization] and
              sharing_mode != account.sharing_mode do
    account
    |> ConnectedAccount.sharing_changeset(%{sharing_mode: sharing_mode})
    |> Repo.update()
  end

  defp maybe_apply_intent_sharing(account, _sharing_mode), do: {:ok, account}

  defp assert_same_mapping(account, attrs) do
    case {
      account.owner_user_id == attrs.owner_user_id,
      account.org_id == attrs.org_id,
      account.provider_id == attrs.provider_id,
      account.provider_slug == attrs.provider_slug
    } do
      {true, true, true, true} -> :ok
      _mismatch -> {:error, :connected_account_mapping_conflict}
    end
  end

  defp find_remote_account(attrs) do
    Repo.get_by(ConnectedAccount,
      workos_connected_account_id: attrs.workos_connected_account_id
    ) ||
      Repo.one(
        from account in ConnectedAccount,
          where:
            account.owner_user_id == ^attrs.owner_user_id and
              account.provider_slug == ^attrs.provider_slug and
              account.org_id == ^attrs.org_id
      )
  end

  defp event_organization(owner, provider_slug, remote_account) do
    case optional_string(remote_account, "organization_id") do
      workos_organization_id when is_binary(workos_organization_id) ->
        case Accounts.get_organization_by_workos_id(workos_organization_id) do
          %Organization{} = organization -> {:ok, organization}
          nil -> {:error, :unmapped_connected_account_organization}
        end

      nil ->
        personal_or_intended_organization(owner, provider_slug, remote_account)
    end
  end

  defp personal_or_intended_organization(owner, provider_slug, remote_account) do
    now = DateTime.utc_now(:second)

    existing =
      case optional_string(remote_account, "id") do
        nil -> nil
        id -> Repo.get_by(ConnectedAccount, workos_connected_account_id: id)
      end

    intent =
      Repo.one(
        from pending in ConnectedAccountIntent,
          where:
            pending.owner_user_id == ^owner.id and pending.provider_slug == ^provider_slug and
              is_nil(pending.consumed_at) and pending.expires_at > ^now,
          order_by: [desc: pending.inserted_at],
          limit: 1,
          preload: [:organization]
      )

    case {existing, intent} do
      {%ConnectedAccount{} = account, _intent} -> {:ok, Repo.get!(Organization, account.org_id)}
      {nil, %ConnectedAccountIntent{organization: organization}} -> {:ok, organization}
      {nil, nil} -> personal_organization(owner)
    end
  end

  defp personal_organization(owner) do
    case Enum.find(Accounts.list_user_organizations(owner), & &1.personal) do
      %Organization{} = organization -> {:ok, organization}
      nil -> {:error, :unmapped_connected_account_organization}
    end
  end

  defp remote_account_attrs(
         owner,
         organization,
         provider_slug,
         remote_account,
         event_type,
         intent \\ nil
       ) do
    with {:ok, workos_connected_account_id} <- required_string(remote_account, "id"),
         {:ok, workos_updated_at} <- remote_timestamp(remote_account),
         {:ok, provider} <- fetch_provider(provider_slug) do
      state = event_state(event_type, optional_string(remote_account, "state"))

      disconnected_at =
        if state == :disconnected,
          do: DateTime.truncate(workos_updated_at, :second)

      {:ok,
       %{
         owner_user_id: owner.id,
         org_id: organization.id,
         provider_id: provider.provider_id,
         provider_slug: provider.slug,
         backend: :workos_pipes,
         workos_connected_account_id: workos_connected_account_id,
         workos_organization_id: organization.workos_organization_id,
         state: state,
         sharing_mode: intent_sharing_mode(intent),
         granted_scopes: string_list(remote_account, "scopes"),
         workos_updated_at: workos_updated_at,
         disconnected_at: disconnected_at
       }}
    end
  end

  defp event_state("pipes.connected_account.disconnected", _state), do: :disconnected

  defp event_state("pipes.connected_account.reauthorization_needed", _state),
    do: :needs_reauthorization

  defp event_state(_event_type, "needs_reauthorization"), do: :needs_reauthorization
  defp event_state(_event_type, _state), do: :connected

  defp intent_sharing_mode(%ConnectedAccountIntent{sharing_mode: sharing_mode}), do: sharing_mode
  defp intent_sharing_mode(_intent), do: nil

  defp validate_connect_scope(%Scope{organization: %Organization{personal: true}}, :private),
    do: :ok

  defp validate_connect_scope(
         %Scope{membership: %{role: role}, organization: %Organization{personal: false}},
         :organization
       )
       when role in [:owner, :admin],
       do: :ok

  defp validate_connect_scope(%Scope{organization: %Organization{personal: false}}, :private),
    do: :ok

  defp validate_connect_scope(_scope, _sharing_mode), do: {:error, :unauthorized}

  defp sharing_change_allowed?(%ConnectedAccount{
         state: :connected,
         owner: %User{deletion_pending_at: nil, deleted_at: nil}
       }),
       do: :ok

  defp sharing_change_allowed?(_account), do: {:error, :connected_account_unavailable}

  defp apply_state_impacts(%ConnectedAccount{state: :connected}), do: :ok

  defp apply_state_impacts(%ConnectedAccount{} = account) do
    CredentialImpacts.disable_triggers(account)
    :ok
  end

  defp remote_provider_index(scope) do
    with workos_user_id when is_binary(workos_user_id) <- scope.user.workos_user_id,
         {:ok, %{"data" => providers}} when is_list(providers) <-
           client().list_providers(
             workos_user_id,
             scope.organization.workos_organization_id
           ) do
      Map.new(providers, &{&1["slug"], &1})
    else
      _other -> %{}
    end
  end

  defp configured_providers do
    Application.get_env(:hermitscale, __MODULE__, [])
    |> Keyword.get(:providers, [])
    |> Enum.map(&normalize_provider/1)
  end

  defp fetch_provider(provider_slug) do
    case Enum.find(configured_providers(), &(&1.slug == provider_slug)) do
      nil -> {:error, :unknown_provider}
      provider -> {:ok, provider}
    end
  end

  defp normalize_provider(provider) do
    %{
      slug: Map.get(provider, :slug) || Map.fetch!(provider, "slug"),
      provider_id: Map.get(provider, :provider_id) || Map.fetch!(provider, "provider_id"),
      name: Map.get(provider, :name) || Map.fetch!(provider, "name"),
      description: Map.get(provider, :description) || Map.get(provider, "description"),
      scopes: Map.get(provider, :scopes) || Map.get(provider, "scopes") || []
    }
  end

  defp append_intent(return_to, token) do
    separator = if String.contains?(return_to, "?"), do: "&", else: "?"
    return_to <> separator <> URI.encode_query(%{"intent" => token})
  end

  defp random_intent_token do
    @intent_token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp token_hash(token), do: :crypto.hash(:sha256, token)

  defp newer_projection?(%DateTime{}, nil), do: true

  defp newer_projection?(%DateTime{} = remote, %DateTime{} = local),
    do: DateTime.after?(remote, local)

  defp remote_timestamp(remote_account) do
    value = fetch_value(remote_account, "updated_at") || fetch_value(remote_account, "created_at")

    case value do
      %DateTime{} = timestamp ->
        {:ok, timestamp}

      timestamp when is_binary(timestamp) ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, parsed, _offset} -> {:ok, parsed}
          {:error, _reason} -> {:error, :invalid_connected_account_timestamp}
        end

      _other ->
        {:error, :invalid_connected_account_timestamp}
    end
  end

  defp required_string(map, key) do
    case fetch_value(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:invalid_connected_account, key}}
    end
  end

  defp optional_string(map, key) do
    case fetch_value(map, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp string_list(map, key) do
    case fetch_value(map, key) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _other -> []
    end
  end

  defp fetch_value(map, key) do
    Map.get(map, key) || Map.get(map, known_atom_key(key))
  end

  defp known_atom_key("id"), do: :id
  defp known_atom_key("user_id"), do: :user_id
  defp known_atom_key("provider_slug"), do: :provider_slug
  defp known_atom_key("organization_id"), do: :organization_id
  defp known_atom_key("state"), do: :state
  defp known_atom_key("scopes"), do: :scopes
  defp known_atom_key("updated_at"), do: :updated_at
  defp known_atom_key("created_at"), do: :created_at

  defp client do
    Application.get_env(:hermitscale, __MODULE__, [])
    |> Keyword.get(:client, Client)
  end

  defp host_allowed?(host, "." <> suffix) do
    host == suffix or String.ends_with?(host, "." <> suffix)
  end

  defp host_allowed?(host, allowed_host), do: host == allowed_host
end
