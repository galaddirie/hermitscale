defmodule Hermitscale.Workflows.Credentials do
  @moduledoc """
  Resolves graph credential references into Runic run context.

  Supported graph bindings:

      %{
        "credentials" => %{
          "providers" => %{
            "google.oauth" => %{"provider" => "google.oauth"}
          },
          "nodes" => %{
            "node_id" => %{"provider" => "google.oauth"}
          }
        }
      }

  A node-local `"credentials"` map is also accepted as a direct override. The
  node-specific binding wins over the provider default.
  """

  alias Hermitscale.Integrations.{ConnectedAccounts, Provider}
  alias Hermitscale.Workflows.{Catalog, Validator}
  alias Runic.Workflow

  @doc """
  Resolves credential bindings and validates the resulting Runic run context.
  """
  def resolve_run_context(graph, %Workflow{} = workflow, base_context \\ %{})
      when is_map(graph) do
    resolve_run_context(graph, workflow, base_context, nil)
  end

  @doc """
  Resolves run context with the graph's trusted WorkOS identities.
  """
  def resolve_run_context(graph, %Workflow{} = workflow, base_context, identity)
      when is_map(graph) and (is_tuple(identity) or is_nil(identity)) do
    with {:ok, credential_context} <- credential_context(graph, identity),
         base_context <- merge_context(Workflow.get_run_context(workflow), base_context),
         run_context <- merge_context(base_context, credential_context),
         :ok <- validate_run_context(workflow, run_context) do
      {:ok, run_context}
    end
  end

  @doc """
  Resolves the credential binding for a single node at call time.

  Unlike `resolve_run_context/3`, which resolves once when a run starts, this
  is for long-lived trigger runtimes that must re-resolve on every poll or
  reconnect so rotated tokens stay fresh. Returns `{:ok, nil}` when the node
  declares no credential requirement or the graph binds none.
  """
  def resolve_node(graph, node_id) when is_map(graph) and is_binary(node_id) do
    resolve_node(graph, node_id, nil)
  end

  @doc """
  Resolves one node credential with its graph's trusted WorkOS identities.
  """
  def resolve_node(graph, node_id, identity)
      when is_map(graph) and is_binary(node_id) and
             (is_tuple(identity) or is_nil(identity)) do
    catalog = Catalog.index()

    node =
      graph
      |> Validator.node_specs()
      |> Enum.find(&(&1["id"] == node_id))

    case node do
      nil ->
        {:error, {:missing_node, node_id}}

      node ->
        with {:ok, {_node_id, %{credentials: credential}}} <-
               node_context(node, graph, catalog, identity) do
          {:ok, credential}
        end
    end
  end

  @doc """
  Returns credential requirements grouped by provider for editor consent flows.
  """
  def requirements(graph) when is_map(graph) do
    catalog = Catalog.index()

    graph
    |> Validator.node_specs()
    |> Enum.reduce(%{}, fn node, acc ->
      with {:ok, module} <- Catalog.fetch(catalog, node["type"], node["version"]),
           %{requires: requires} <- module.__catalog_node__(),
           requirement when is_list(requirement) <- Keyword.get(requires, :credentials),
           provider when is_binary(provider) <- Keyword.get(requirement, :provider) do
        scopes = Keyword.get(requirement, :scopes, [])

        Map.update(
          acc,
          provider,
          %{provider: provider, scopes: scopes, nodes: [node["id"]]},
          &merge_requirement(&1, scopes, node["id"])
        )
      else
        _other -> acc
      end
    end)
    |> Map.values()
    |> Enum.map(&Map.update!(&1, :scopes, fn scopes -> Enum.sort(Enum.uniq(scopes)) end))
    |> Enum.sort_by(& &1.provider)
  end

  defp credential_context(graph, identity) do
    catalog = Catalog.index()

    graph
    |> Validator.node_specs()
    # Trigger entry steps never consume credentials at run time (their tokens
    # are resolved by the trigger runtime per poll/connect), so fetching one
    # per run would be a wasted provider round-trip.
    |> Enum.reject(&trigger_node?(&1, catalog))
    |> Enum.reduce_while({:ok, %{}}, fn node, {:ok, context} ->
      case node_context(node, graph, catalog, identity) do
        {:ok, nil} -> {:cont, {:ok, context}}
        {:ok, {node_id, node_context}} -> {:cont, {:ok, Map.put(context, node_id, node_context)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp trigger_node?(node, catalog) do
    case Catalog.fetch(catalog, node["type"], node["version"]) do
      {:ok, module} -> match?(%{kind: :trigger}, module.__catalog_node__())
      {:error, :not_found} -> false
    end
  end

  defp node_context(node, graph, catalog, identity) do
    with {:ok, module} <- Catalog.fetch(catalog, node["type"], node["version"]),
         %{requires: requires} <- module.__catalog_node__(),
         requirement when is_list(requirement) <- Keyword.get(requires, :credentials),
         {:ok, ref} when is_map(ref) <- credential_ref(graph, node, requirement) do
      resolve_node_credentials(node["id"], requirement, ref, identity)
    else
      {:ok, nil} -> {:ok, nil}
      nil -> {:ok, nil}
      {:error, reason} -> {:error, reason}
      _other -> {:ok, nil}
    end
  end

  defp credential_ref(graph, node, requirement) do
    provider = Keyword.get(requirement, :provider)
    node_id = node["id"]

    ref =
      node["credentials"] ||
        get_in(graph, ["credentials", "nodes", node_id]) ||
        provider_ref(graph, provider)

    case ref do
      ref when is_map(ref) -> {:ok, ref}
      nil -> {:ok, nil}
      _other -> {:error, {:invalid_credential_ref, node_id}}
    end
  end

  defp provider_ref(_graph, nil), do: nil
  defp provider_ref(graph, provider), do: get_in(graph, ["credentials", "providers", provider])

  defp resolve_node_credentials(node_id, requirement, ref, identity) do
    expected_provider = Keyword.get(requirement, :provider)
    scopes = Keyword.get(requirement, :scopes, [])

    with {:ok, provider} <- provider_id(expected_provider, ref),
         :ok <- validate_provider_match(node_id, expected_provider, provider),
         {:ok, credential} <-
           resolve_credential(node_id, provider, ref, scopes, identity) do
      {:ok, {node_id, %{credentials: credential}}}
    end
  end

  defp provider_id(nil, ref) do
    case ref_value(ref, :provider) do
      provider when is_binary(provider) -> {:ok, provider}
      _other -> {:error, :missing_credential_provider}
    end
  end

  defp provider_id(provider, ref) when is_binary(provider) do
    case ref_value(ref, :provider) do
      nil -> {:ok, provider}
      ref_provider when is_binary(ref_provider) -> {:ok, ref_provider}
      _other -> {:error, :missing_credential_provider}
    end
  end

  defp validate_provider_match(_node_id, nil, _provider), do: :ok

  defp validate_provider_match(node_id, expected, provider) do
    ref_provider = provider

    case ref_provider do
      ^expected -> :ok
      _other -> {:error, {:credential_provider_mismatch, node_id, expected, ref_provider}}
    end
  end

  defp resolve_credential(node_id, "google.oauth" = provider, ref, scopes, identity) do
    case ref_value(ref, :connected_account_id) do
      nil ->
        case ConnectedAccounts.credential_ref(identity, provider, scopes) do
          {:ok, credential_ref} -> {:ok, credential_ref}
          {:error, reason} -> {:error, {:credential_fetch_failed, node_id, provider, reason}}
        end

      _legacy_id ->
        {:error, {:credential_fetch_failed, node_id, provider, :legacy_credential_reference}}
    end
  end

  defp resolve_credential(node_id, provider, ref, scopes, _identity) do
    case Provider.fetch_token(provider, ref, scopes) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:error, {:credential_fetch_failed, node_id, provider, reason}}
    end
  end

  @doc """
  Whether a definition binds provider credentials to its creator.
  """
  def bound?(definition) when is_map(definition) do
    case Map.get(definition, "credentials") do
      credentials when is_map(credentials) and map_size(credentials) > 0 -> true
      _ -> Enum.any?(Map.values(definition), &bound?/1)
    end
  end

  def bound?(values) when is_list(values), do: Enum.any?(values, &bound?/1)
  def bound?(_value), do: false

  @doc """
  Authorizes use of creator-owned credential bindings.
  """
  def authorize(scope, graph) do
    case bound?(graph.definition) do
      false -> :ok
      true when scope.user.id == graph.created_by_user_id -> :ok
      true -> {:error, :credential_owner_required}
    end
  end

  defp validate_run_context(workflow, run_context) do
    case Workflow.validate_run_context(workflow, run_context) do
      :ok -> :ok
      {:error, missing} -> {:error, {:missing_run_context, missing}}
    end
  end

  defp merge_context(base_context, credential_context) do
    Map.merge(base_context, credential_context, fn _key, base, credentials ->
      merge_node_context(base, credentials)
    end)
  end

  defp merge_node_context(base, credentials) when is_map(base) and is_map(credentials) do
    Map.merge(base, credentials)
  end

  defp merge_node_context(_base, credentials), do: credentials

  defp ref_value(ref, key), do: Map.get(ref, key) || Map.get(ref, Atom.to_string(key))

  defp merge_requirement(requirement, scopes, node_id) do
    requirement
    |> Map.update!(:scopes, &(scopes ++ &1))
    |> Map.update!(:nodes, &[node_id | &1])
  end
end
