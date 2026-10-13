defmodule Hermitscale.Workflows.Credentials do
  @moduledoc "Canonical node account selection and non-secret runtime references."
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Integrations.{ConnectedAccounts, ExecutionContext}
  alias Hermitscale.Workflows.{Catalog, Validator}
  alias Runic.Workflow

  @reserved ~w(credentials credential_ref actor_user_id user_id organization_id execution_context execution_actor_user_id owner scope)

  @doc "Resolves per-node references from trusted execution identity, never from expression data."
  def resolve_run_context(graph, workflow, base_context \\ %{}, identity \\ nil)

  def resolve_run_context(graph, %Workflow{} = workflow, base_context, identity) do
    with :ok <- validate_context(base_context),
         {:ok, credential_context} <- contexts(graph, identity),
         context = Map.merge(Workflow.get_run_context(workflow), base_context),
         context =
           Map.merge(context, credential_context, fn _id, base, credentials ->
             Map.merge(if(is_map(base), do: base, else: %{}), credentials)
           end),
         :ok <- validate_run_context(workflow, context) do
      {:ok, context}
    end
  end

  @doc "Resolves a trigger node's reference at each poll or reconnect."
  def resolve_node(graph, node_id, identity \\ nil) do
    case Enum.find(Validator.node_specs(graph), &(&1["id"] == node_id)) do
      nil -> {:error, {:missing_node, node_id}}
      node -> node_reference(node, identity)
    end
  end

  @doc "Checks every selection before run admission or activation."
  def readiness(graph, %ExecutionContext{} = identity) do
    with {:ok, _context} <- contexts(graph, identity), do: :ok
  end

  @doc "Returns the catalog credential requirement for a node."
  def requirement(%{"type" => type, "version" => version})
      when is_binary(type) and is_integer(version) do
    case Catalog.fetch(type, version) do
      {:ok, module} -> Keyword.get(module.__catalog_node__().requires, :credentials)
      {:error, :not_found} -> nil
    end
  end

  def requirement(_node), do: nil

  @doc "Collects requirements without retrieving secrets."
  def requirements(graph) do
    graph
    |> Validator.node_specs()
    |> Enum.reduce(%{}, fn node, acc ->
      case requirement(node) do
        requirement when is_list(requirement) ->
          provider =
            Keyword.get(requirement, :provider) || get_in(node, ["connection", "provider"])

          scopes = Keyword.get(requirement, :scopes, [])

          case provider do
            nil ->
              acc

            provider ->
              Map.update(
                acc,
                provider,
                %{provider: provider, scopes: scopes, nodes: [node["id"]]},
                fn r ->
                  %{r | scopes: Enum.uniq(r.scopes ++ scopes), nodes: [node["id"] | r.nodes]}
                end
              )
          end

        nil ->
          acc
      end
    end)
    |> Map.values()
    |> Enum.map(&%{&1 | nodes: Enum.reverse(&1.nodes)})
    |> Enum.sort_by(& &1.provider)
  end

  @doc "Fills missing selections with the only compatible org account; keeps existing choices stable."
  def select_accounts(%Scope{} = scope, graph) do
    graph["nodes"]
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, nodes} ->
      case select_node(scope, node) do
        {:ok, selected} -> {:cont, {:ok, [selected | nodes]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, Map.put(graph, "nodes", Enum.reverse(nodes))}
      {:error, _reason} = error -> error
    end
  end

  defp select_node(scope, node) do
    case {node["connection"], requirement(node)} do
      {nil, requirement} when is_list(requirement) ->
        case Keyword.get(requirement, :provider) do
          nil ->
            {:ok, node}

          provider ->
            case ConnectedAccounts.select(scope, provider, Keyword.get(requirement, :scopes, [])) do
              {:ok, selection} -> {:ok, Map.put(node, "connection", selection)}
              {:error, :connection_setup_required} -> {:ok, node}
              {:error, _reason} = error -> error
            end
        end

      _ ->
        {:ok, node}
    end
  end

  @doc "Snapshots selected accounts for run provenance and resume."
  def selections(graph),
    do:
      graph
      |> Validator.node_specs()
      |> Enum.filter(&is_map(&1["connection"]))
      |> Map.new(&{&1["id"], &1["connection"]})

  @doc "Restores a run's selected accounts without changing graph topology."
  def with_selections(graph, selections) do
    Map.update!(graph, "nodes", fn nodes ->
      Enum.map(nodes, fn node ->
        case Map.fetch(selections, node["id"]) do
          {:ok, connection} -> Map.put(node, "connection", connection)
          :error -> Map.delete(node, "connection")
        end
      end)
    end)
  end

  defp contexts(graph, identity) do
    graph
    |> Validator.node_specs()
    |> Enum.reduce_while({:ok, %{}}, fn node, {:ok, acc} ->
      case runtime_context(node, identity) do
        {:ok, context} ->
          {:cont, {:ok, Map.put(acc, node["id"], context)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp runtime_context(node, identity) do
    with {:ok, reference} <- node_reference(node, identity) do
      context =
        if reference != nil or requirement(node) == [], do: %{credentials: reference}, else: %{}

      {:ok, module} = Catalog.fetch(node["type"], node["version"])

      case Keyword.has_key?(module.__catalog_node__().requires, :execution_context) do
        false ->
          {:ok, context}

        true when is_struct(identity, ExecutionContext) ->
          {:ok, Map.put(context, :execution_context, identity)}

        true ->
          {:error, :execution_identity_required}
      end
    end
  end

  defp node_reference(node, identity) do
    case {requirement(node), node["connection"]} do
      {nil, nil} ->
        {:ok, nil}

      {[], nil} ->
        {:ok, nil}

      {requirement, nil} when is_list(requirement) ->
        {:error, {:connection_setup_required, node["id"]}}

      {requirement, selection} when is_list(requirement) ->
        with :ok <-
               ConnectedAccounts.validate_selection(
                 selection,
                 Keyword.get(requirement, :provider)
               ),
             {:ok, reference} <-
               ConnectedAccounts.credential_ref(
                 identity,
                 selection,
                 Keyword.get(requirement, :scopes, [])
               ) do
          {:ok, reference}
        else
          {:error, reason} -> {:error, {:connection_not_ready, node["id"], reason}}
        end

      _ ->
        {:error, {:invalid_connection, node["id"]}}
    end
  end

  defp validate_context(context) when is_map(context) do
    case reserved_context?(context) do
      true -> {:error, :reserved_run_context}
      false -> :ok
    end
  end

  defp validate_context(_context), do: {:error, :invalid_run_context}
  defp reserved_context?(%_{}), do: true

  defp reserved_context?(map) when is_map(map),
    do:
      Enum.any?(map, fn {key, value} ->
        to_string(key) in @reserved or reserved_context?(value)
      end)

  defp reserved_context?(list) when is_list(list), do: Enum.any?(list, &reserved_context?/1)
  defp reserved_context?(_value), do: false

  defp validate_run_context(workflow, context) do
    case Workflow.validate_run_context(workflow, context) do
      :ok -> :ok
      {:error, missing} -> {:error, {:missing_run_context, missing}}
    end
  end
end
