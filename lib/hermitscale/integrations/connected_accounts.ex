defmodule Hermitscale.Integrations.ConnectedAccounts do
  @moduledoc "Organization connection status, selection, readiness and immediate credential vending. WorkOS owns all state and secrets."
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Authorization
  alias Hermitscale.Integrations.{CredentialRef, ExecutionContext, Provider}
  alias Hermitscale.WorkOS.Client

  @doc "Lists non-secret account status for the caller's verified organization."
  def list(%Scope{} = scope), do: list_for_org(Scope.organization_id!(scope))

  defp list_for_org(org_id) do
    with {:ok, %{"data" => providers}} <- Client.adapter(__MODULE__).list_org_providers(org_id) do
      accounts =
        Enum.flat_map(providers, fn provider ->
          provider_accounts(provider)
          |> Enum.filter(&(&1["organization_id"] == org_id and is_nil(&1["user_id"])))
          |> Enum.map(fn account ->
            account
            |> Map.take(
              ~w(id organization_id state scopes auth_method account_display_name state_reason established_by_user_id)
            )
            |> Map.put("provider", provider["slug"])
          end)
        end)

      {:ok, accounts}
    end
  end

  defp provider_accounts(%{"connected_accounts" => accounts}) when is_list(accounts), do: accounts
  defp provider_accounts(%{"connected_account" => account}) when is_map(account), do: [account]
  defp provider_accounts(_provider), do: []

  @doc "Validates a canonical graph selection without accepting graph-supplied authority."
  def validate_selection(selection, expected) do
    with {:ok, _descriptor} <- selection_descriptor(selection, expected), do: :ok
  end

  defp selection_descriptor(
         %{"provider" => provider, "account_id" => account_id} = selection,
         expected
       )
       when is_binary(provider) and is_binary(account_id) and account_id != "" do
    with true <- Enum.sort(Map.keys(selection)) == ["account_id", "provider"],
         true <- is_nil(expected) or expected == provider,
         {:ok, descriptor} <- Provider.descriptor(provider) do
      {:ok, descriptor}
    else
      false -> {:error, :invalid_connection}
      {:error, _reason} = error -> error
    end
  end

  defp selection_descriptor(_selection, _expected), do: {:error, :invalid_connection}

  @doc "Constructs a validated non-secret reference after checking the account's current readiness."
  def credential_ref(
        %ExecutionContext{organization_id: org_id, actor_user_id: user_id} = context,
        selection,
        scopes
      )
      when is_list(scopes) and is_binary(org_id) and org_id != "" and is_binary(user_id) and
             user_id != "" do
    with {:ok, descriptor} <- selection_descriptor(selection, nil),
         {:ok, accounts} <- list_for_org(context.organization_id),
         {:ok, _account} <- ready_account(accounts, selection, scopes, descriptor) do
      {:ok,
       %CredentialRef{
         execution_context: context,
         provider_id: selection["provider"],
         account_id: selection["account_id"],
         required_scopes: Enum.uniq(scopes)
       }}
    end
  end

  def credential_ref(_context, _selection, _scopes), do: {:error, :missing_execution_identity}

  @doc "Chooses the only compatible account; several matches require an explicit choice."
  def select(%Scope{} = scope, provider, scopes) do
    with {:ok, descriptor} <- Provider.descriptor(provider),
         {:ok, accounts} <- list(scope) do
      case Enum.filter(accounts, &ready?(&1, provider, scopes, descriptor)) do
        [account] -> {:ok, %{"provider" => provider, "account_id" => account["id"]}}
        [] -> {:error, :connection_setup_required}
        _ -> {:error, :account_selection_required}
      end
    end
  end

  defp ready_account(accounts, selection, scopes, descriptor) do
    case Enum.find(
           accounts,
           &(&1["id"] == selection["account_id"] and &1["provider"] == selection["provider"])
         ) do
      nil ->
        {:error, :account_not_found}

      %{"state" => "needs_reauthorization"} ->
        {:error, :needs_reauthorization}

      account ->
        case ready?(account, selection["provider"], scopes, descriptor) do
          true -> {:ok, account}
          false -> {:error, :insufficient_scopes}
        end
    end
  end

  defp ready?(account, provider, scopes, descriptor) do
    account["provider"] == provider and account["state"] == "connected" and
      account["auth_method"] in descriptor.auth_methods and
      (account["auth_method"] == "api_key" or
         Enum.all?(scopes, &(&1 in (account["scopes"] || []))))
  end

  @doc "Vends immediately before an effect, observing membership, rotation and consent changes."
  def vend(%CredentialRef{} = ref) do
    context = ref.execution_context
    selection = %{"provider" => ref.provider_id, "account_id" => ref.account_id}

    with {:ok, _scope} <- Authorization.execution_scope(context),
         {:ok, descriptor} <- Provider.descriptor(ref.provider_id),
         {:ok, accounts} <- list_for_org(context.organization_id),
         {:ok, _account} <- ready_account(accounts, selection, ref.required_scopes, descriptor),
         {:ok, credential} <-
           Client.adapter(__MODULE__).vend_credentials(
             descriptor.slug,
             context.actor_user_id,
             context.organization_id,
             ref.account_id
           ),
         :ok <- validate_credential(credential, descriptor, ref.required_scopes) do
      {:ok, credential}
    end
  end

  defp validate_credential(
         %{auth_method: method, scopes: scopes, missing_scopes: missing},
         descriptor,
         required
       ) do
    cond do
      method not in descriptor.auth_methods -> {:error, :unsupported_auth_method}
      method == "api_key" -> :ok
      missing != [] or not Enum.all?(required, &(&1 in scopes)) -> {:error, :insufficient_scopes}
      true -> :ok
    end
  end

  def connect(%Scope{} = scope, provider, return_to, account_id \\ nil) do
    with :ok <- Authorization.authorize(scope, "connections:manage"),
         {:ok, descriptor} <- Provider.descriptor(provider),
         true <- "oauth" in descriptor.auth_methods,
         :ok <- management_selection(scope, provider, account_id) do
      Client.adapter(__MODULE__).authorize_connection(
        descriptor.slug,
        scope.user.id,
        Scope.organization_id!(scope),
        return_to,
        account_id
      )
    else
      false -> {:error, :api_key_required}
      {:error, _reason} = error -> error
    end
  end

  def rotate(%Scope{} = scope, provider, account_id, secret)
      when is_binary(secret) and secret != "" do
    with :ok <- Authorization.authorize(scope, "connections:manage"),
         {:ok, descriptor} <- Provider.descriptor(provider),
         true <- "api_key" in descriptor.auth_methods,
         :ok <- management_selection(scope, provider, account_id) do
      case Client.adapter(__MODULE__).rotate_api_key(
             descriptor.slug,
             scope.user.id,
             Scope.organization_id!(scope),
             account_id,
             secret
           ) do
        {:ok, _account} -> {:ok, :connected}
        {:error, _reason} = error -> error
      end
    else
      false -> {:error, :unsupported_auth_method}
      {:error, _reason} = error -> error
    end
  end

  def rotate(_scope, _provider, _account_id, _secret), do: {:error, :invalid_secret}

  def disconnect(%Scope{} = scope, provider, account_id) do
    with :ok <- Authorization.authorize(scope, "connections:manage"),
         {:ok, descriptor} <- Provider.descriptor(provider),
         :ok <- management_selection(scope, provider, account_id) do
      Client.adapter(__MODULE__).disconnect_account(
        descriptor.slug,
        Scope.organization_id!(scope),
        account_id
      )
    end
  end

  defp management_selection(_scope, _provider, nil), do: :ok

  defp management_selection(scope, provider, id) do
    with {:ok, accounts} <- list(scope) do
      case Enum.any?(accounts, &(&1["provider"] == provider and &1["id"] == id)) do
        true -> :ok
        false -> {:error, :account_not_found}
      end
    end
  end
end
