defmodule Hermitscale.Workflows.Catalog do
  @moduledoc """
  Discovers workflow catalog nodes from deployed modules.
  """

  @app :hermitscale
  @cache_key {__MODULE__, :index}

  @doc """
  Returns the cached catalog index keyed by `{id, version}`.
  """
  def index do
    case :persistent_term.get(@cache_key, :missing) do
      :missing -> refresh!()
      index -> index
    end
  end

  @doc """
  Rebuilds the catalog index from loaded application modules.
  """
  def refresh! do
    {:ok, modules} = :application.get_key(@app, :modules)

    index =
      Enum.reduce(modules, %{}, fn module, acc ->
        if catalog_node?(module) do
          spec = module.__catalog_node__()
          key = {spec.id, spec.version}

          case Map.fetch(acc, key) do
            {:ok, existing} ->
              raise ArgumentError,
                    "duplicate workflow catalog node #{spec.id}@#{spec.version}: " <>
                      "#{inspect(existing)} and #{inspect(module)}"

            :error ->
              Map.put(acc, key, module)
          end
        else
          acc
        end
      end)

    :persistent_term.put(@cache_key, index)
    index
  end

  @doc """
  Fetches a catalog node module.
  """
  def fetch(index \\ index(), type, version) do
    case Map.fetch(index, {type, version}) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Fetches a catalog node module or raises.
  """
  def fetch!(index \\ index(), type, version) do
    case fetch(index, type, version) do
      {:ok, module} ->
        module

      {:error, :not_found} ->
        raise ArgumentError, "catalog node #{type}@#{version} not found in deployed code"
    end
  end

  @doc """
  Projects the in-code catalog into editor-friendly JSON data.
  """
  def manifest do
    index()
    |> Map.values()
    |> Enum.map(fn module ->
      spec = module.__catalog_node__()

      %{
        id: spec.id,
        version: spec.version,
        kind: spec.kind,
        inputs: spec.inputs,
        outputs: spec.outputs,
        deprecated: spec.deprecated,
        params_schema: Hermitscale.Workflows.JsonSchema.from_nimble(spec.params_schema)
      }
    end)
    |> Enum.sort_by(&{&1.id, &1.version})
  end

  defp catalog_node?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__catalog_node__, 0)
  end
end
